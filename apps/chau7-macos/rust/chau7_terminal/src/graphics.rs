//! Graphics protocol interceptor for terminal image protocols.
//!
//! Sits between the PTY reader and VTE processor, scanning raw bytes for
//! image escape sequences (iTerm2 OSC 1337, Sixel DCS, Kitty APC).
//! Graphics bytes are accumulated and emitted as events; non-graphics
//! bytes pass through to alacritty_terminal's VTE processor unchanged.
//!
//! Architecture: PTY → GraphicsInterceptor::feed() → (passthrough, events)
//!   passthrough → processor.advance()  (normal terminal data)
//!   events      → image decode queue   (graphics data)

use log::{debug, trace, warn};

// ============================================================================
// Public Types
// ============================================================================

/// A decoded graphics event extracted from the PTY byte stream.
#[derive(Debug)]
pub enum GraphicsEvent {
    /// iTerm2 inline image (OSC 1337;File=...).
    /// Contains the raw args string and base64-encoded image data.
    ITerm2 {
        args: String,
        base64_data: Vec<u8>,
    },
    /// Sixel image (DCS Pn;Pn;Pn q ... ST).
    /// Contains the raw sixel data bytes (everything after 'q' up to ST).
    Sixel {
        params: Vec<u8>,
        data: Vec<u8>,
    },
    /// Kitty graphics protocol (ESC_G...ST).
    /// Contains the control key=value string and optional base64 payload.
    Kitty {
        control: String,
        payload: Vec<u8>,
    },
}

/// A decoded image ready for display, with RGBA pixel data.
#[derive(Debug)]
#[allow(dead_code)]
pub struct DecodedImage {
    pub id: u64,
    pub width: u32,
    pub height: u32,
    /// RGBA pixel data, row-major, 4 bytes per pixel.
    pub rgba: Vec<u8>,
    /// The cursor row at the time the image was received (grid-relative).
    pub anchor_row: i32,
    /// The cursor column at the time the image was received.
    pub anchor_col: u16,
    /// Protocol that produced this image.
    pub protocol: ImageProtocol,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum ImageProtocol {
    ITerm2 = 0,
    Sixel = 1,
    Kitty = 2,
}

// ============================================================================
// Buffer size limits (DoS prevention)
// ============================================================================

/// Max bytes for a single iTerm2 image sequence (base64-encoded).
const ITERM2_MAX_BYTES: usize = 64 * 1024 * 1024; // 64MB

/// Max bytes for sixel data.
const SIXEL_MAX_BYTES: usize = 64 * 1024 * 1024; // 64MB

/// Max bytes for a Kitty graphics payload.
const KITTY_MAX_BYTES: usize = 64 * 1024 * 1024; // 64MB

// ============================================================================
// State Machine
// ============================================================================

/// Internal state for the byte-level scanner.
#[derive(Debug)]
enum State {
    /// Normal pass-through mode.
    Ground,
    /// Saw ESC (0x1B), waiting for next byte to determine sequence type.
    Esc,
    /// Saw ESC P — potential DCS (Sixel) sequence. Accumulating parameters.
    DcsParams,
    /// Inside Sixel data (saw DCS params then 'q').
    Sixel,
    /// Sixel: saw ESC inside sixel data, waiting for '\' (ST) or other.
    SixelEsc,
    /// Saw ESC _ — APC sequence. Checking for 'G' (Kitty).
    Apc,
    /// Inside Kitty graphics control data (before ';' payload separator).
    KittyControl,
    /// Inside Kitty graphics payload (after ';').
    KittyPayload,
    /// Kitty: saw ESC inside payload, waiting for '\' (ST).
    KittyEsc,
    /// Saw ESC ] — OSC sequence. Accumulating to check for "1337".
    Osc,
    /// Inside OSC 1337 — accumulating iTerm2 File= args.
    ITermArgs,
    /// Inside iTerm2 base64 data (after ':').
    ITermData,
    /// iTerm2: saw ESC inside data, waiting for '\' (ST).
    ITermEsc,
}

/// Pre-filter that intercepts graphics escape sequences from raw PTY bytes.
///
/// Usage:
/// ```ignore
/// let mut interceptor = GraphicsInterceptor::new();
/// let (passthrough, events) = interceptor.feed(pty_bytes);
/// processor.advance(&mut term, passthrough); // non-graphics to VTE
/// for event in events { handle_image(event); }
/// ```
pub struct GraphicsInterceptor {
    state: State,
    /// Buffer for non-graphics bytes to forward to VTE.
    passthrough: Vec<u8>,
    /// Accumulator for DCS parameters (before the 'q' final char).
    dcs_params: Vec<u8>,
    /// Accumulator for Sixel data bytes.
    sixel_buf: Vec<u8>,
    /// Accumulator for Kitty control string (key=value pairs).
    kitty_control: Vec<u8>,
    /// Accumulator for Kitty base64 payload.
    kitty_payload: Vec<u8>,
    /// Accumulator for OSC prefix (to match "1337").
    osc_prefix: Vec<u8>,
    /// Accumulator for iTerm2 args (between "File=" and ":").
    iterm_args: Vec<u8>,
    /// Accumulator for iTerm2 base64 data (after ":").
    iterm_data: Vec<u8>,
    /// Whether each protocol is enabled.
    pub sixel_enabled: bool,
    pub kitty_enabled: bool,
    pub iterm2_enabled: bool,
}

impl GraphicsInterceptor {
    pub fn new() -> Self {
        Self {
            state: State::Ground,
            passthrough: Vec::with_capacity(4096),
            dcs_params: Vec::new(),
            sixel_buf: Vec::new(),
            kitty_control: Vec::new(),
            kitty_payload: Vec::new(),
            osc_prefix: Vec::new(),
            iterm_args: Vec::new(),
            iterm_data: Vec::new(),
            sixel_enabled: false,
            kitty_enabled: false,
            iterm2_enabled: true, // iTerm2 on by default
        }
    }

    /// Feed raw PTY bytes through the interceptor.
    ///
    /// Returns a slice of passthrough bytes (forward to VTE) and a vec of
    /// extracted graphics events.
    pub fn feed<'a>(&'a mut self, input: &[u8]) -> (&'a [u8], Vec<GraphicsEvent>) {
        self.passthrough.clear();
        let mut events = Vec::new();
        let mut i = 0;

        while i < input.len() {
            let byte = input[i];
            match self.state {
                State::Ground => {
                    // Use memchr to bulk-scan for ESC (0x1B), skipping plain text bytes
                    if let Some(esc_offset) = memchr::memchr(0x1B, &input[i..]) {
                        // Copy everything before the ESC as passthrough
                        if esc_offset > 0 {
                            self.passthrough.extend_from_slice(&input[i..i + esc_offset]);
                        }
                        i += esc_offset + 1; // skip past the ESC byte
                        self.state = State::Esc;
                    } else {
                        // No ESC found — rest of input is all passthrough
                        self.passthrough.extend_from_slice(&input[i..]);
                        break;
                    }
                    continue;
                }

                State::Esc => match byte {
                    // ESC P → DCS (potential Sixel)
                    0x50 if self.sixel_enabled => {
                        self.dcs_params.clear();
                        self.state = State::DcsParams;
                    }
                    // ESC _ → APC (potential Kitty)
                    0x5F if self.kitty_enabled => {
                        self.state = State::Apc;
                    }
                    // ESC ] → OSC (potential iTerm2)
                    0x5D if self.iterm2_enabled => {
                        self.osc_prefix.clear();
                        self.state = State::Osc;
                    }
                    _ => {
                        // Not a graphics sequence — pass ESC + byte through
                        self.passthrough.push(0x1B);
                        self.passthrough.push(byte);
                        self.state = State::Ground;
                    }
                },

                // ── DCS / Sixel ──────────────────────────────────────

                State::DcsParams => {
                    if byte == b'q' {
                        // Final char 'q' → entering Sixel data mode
                        self.sixel_buf.clear();
                        self.state = State::Sixel;
                        trace!("GraphicsInterceptor: Sixel sequence started");
                    } else if byte.is_ascii_digit() || byte == b';' {
                        // Parameter bytes (digits and ';')
                        self.dcs_params.push(byte);
                    } else {
                        // Not Sixel — this is some other DCS. Pass through.
                        self.passthrough.push(0x1B);
                        self.passthrough.push(0x50); // P
                        self.passthrough.extend_from_slice(&self.dcs_params);
                        self.passthrough.push(byte);
                        self.dcs_params.clear();
                        self.state = State::Ground;
                    }
                }

                State::Sixel => {
                    if byte == 0x1B {
                        self.state = State::SixelEsc;
                    } else if byte == 0x9C {
                        // 8-bit ST — end of Sixel
                        self.emit_sixel(&mut events);
                        self.state = State::Ground;
                    } else {
                        if self.sixel_buf.len() < SIXEL_MAX_BYTES {
                            self.sixel_buf.push(byte);
                        } else {
                            warn!("GraphicsInterceptor: Sixel data exceeded {}MB, discarding",
                                  SIXEL_MAX_BYTES / (1024 * 1024));
                            self.sixel_buf.clear();
                            self.dcs_params.clear();
                            self.state = State::Ground;
                        }
                    }
                }

                State::SixelEsc => {
                    if byte == 0x5C {
                        // ESC \ = ST — end of Sixel
                        self.emit_sixel(&mut events);
                        self.state = State::Ground;
                    } else {
                        // ESC followed by something else inside Sixel — accumulate both
                        self.sixel_buf.push(0x1B);
                        self.sixel_buf.push(byte);
                        self.state = State::Sixel;
                    }
                }

                // ── APC / Kitty ──────────────────────────────────────

                State::Apc => {
                    if byte == b'G' {
                        // ESC _ G → Kitty graphics!
                        self.kitty_control.clear();
                        self.kitty_payload.clear();
                        self.state = State::KittyControl;
                        trace!("GraphicsInterceptor: Kitty graphics sequence started");
                    } else {
                        // Some other APC — pass through
                        self.passthrough.push(0x1B);
                        self.passthrough.push(0x5F); // _
                        self.passthrough.push(byte);
                        self.state = State::Ground;
                    }
                }

                State::KittyControl => {
                    if byte == b';' {
                        // Separator between control and payload
                        self.state = State::KittyPayload;
                    } else if byte == 0x1B {
                        self.state = State::KittyEsc;
                    } else if byte == 0x9C {
                        // 8-bit ST — end with no payload
                        self.emit_kitty(&mut events);
                        self.state = State::Ground;
                    } else {
                        self.kitty_control.push(byte);
                    }
                }

                State::KittyPayload => {
                    if byte == 0x1B {
                        self.state = State::KittyEsc;
                    } else if byte == 0x9C {
                        self.emit_kitty(&mut events);
                        self.state = State::Ground;
                    } else {
                        if self.kitty_payload.len() < KITTY_MAX_BYTES {
                            self.kitty_payload.push(byte);
                        } else {
                            warn!("GraphicsInterceptor: Kitty payload exceeded limit, discarding");
                            self.kitty_control.clear();
                            self.kitty_payload.clear();
                            self.state = State::Ground;
                        }
                    }
                }

                State::KittyEsc => {
                    if byte == 0x5C {
                        // ESC \ = ST — end of Kitty
                        self.emit_kitty(&mut events);
                        self.state = State::Ground;
                    } else {
                        // ESC followed by something else
                        // In Kitty control/payload, this shouldn't happen. Discard.
                        warn!("GraphicsInterceptor: Unexpected ESC {:02x} in Kitty sequence", byte);
                        self.kitty_control.clear();
                        self.kitty_payload.clear();
                        self.state = State::Ground;
                    }
                }

                // ── OSC / iTerm2 ─────────────────────────────────────

                State::Osc => {
                    if byte == b';' {
                        // Check if we accumulated "1337"
                        if self.osc_prefix == b"1337" {
                            self.iterm_args.clear();
                            self.iterm_data.clear();
                            self.state = State::ITermArgs;
                            trace!("GraphicsInterceptor: iTerm2 OSC 1337 sequence started");
                        } else {
                            // Not iTerm2 — pass through the whole OSC prefix
                            self.passthrough.push(0x1B);
                            self.passthrough.push(0x5D); // ]
                            self.passthrough.extend_from_slice(&self.osc_prefix);
                            self.passthrough.push(b';');
                            self.osc_prefix.clear();
                            self.state = State::Ground;
                        }
                    } else if byte == 0x07 || byte == 0x9C {
                        // BEL or 8-bit ST — OSC terminated before ';'
                        self.passthrough.push(0x1B);
                        self.passthrough.push(0x5D);
                        self.passthrough.extend_from_slice(&self.osc_prefix);
                        self.passthrough.push(byte);
                        self.osc_prefix.clear();
                        self.state = State::Ground;
                    } else if byte == 0x1B {
                        // Potential ESC \ (ST)
                        // For non-1337 OSC, just pass through
                        self.passthrough.push(0x1B);
                        self.passthrough.push(0x5D);
                        self.passthrough.extend_from_slice(&self.osc_prefix);
                        self.passthrough.push(0x1B);
                        self.osc_prefix.clear();
                        self.state = State::Ground;
                    } else {
                        self.osc_prefix.push(byte);
                        // Sanity: OSC number shouldn't be longer than ~10 chars
                        if self.osc_prefix.len() > 16 {
                            self.passthrough.push(0x1B);
                            self.passthrough.push(0x5D);
                            self.passthrough.extend_from_slice(&self.osc_prefix);
                            self.osc_prefix.clear();
                            self.state = State::Ground;
                        }
                    }
                }

                State::ITermArgs => {
                    if byte == b':' {
                        // ':' separates args from base64 data
                        self.state = State::ITermData;
                    } else if byte == 0x07 {
                        // BEL — terminated in args (no data). Unusual but handle it.
                        self.iterm_args.clear();
                        self.state = State::Ground;
                    } else if byte == 0x1B {
                        self.state = State::ITermEsc;
                    } else {
                        self.iterm_args.push(byte);
                    }
                }

                State::ITermData => {
                    if byte == 0x07 {
                        // BEL terminator — end of iTerm2 image
                        self.emit_iterm2(&mut events);
                        self.state = State::Ground;
                    } else if byte == 0x1B {
                        self.state = State::ITermEsc;
                    } else {
                        if self.iterm_data.len() < ITERM2_MAX_BYTES {
                            self.iterm_data.push(byte);
                        } else {
                            warn!("GraphicsInterceptor: iTerm2 data exceeded limit, discarding");
                            self.iterm_args.clear();
                            self.iterm_data.clear();
                            self.state = State::Ground;
                        }
                    }
                }

                State::ITermEsc => {
                    if byte == 0x5C {
                        // ESC \ = ST — end of iTerm2
                        if !self.iterm_data.is_empty() {
                            self.emit_iterm2(&mut events);
                        } else {
                            // Was in args, terminated early
                            self.iterm_args.clear();
                        }
                        self.state = State::Ground;
                    } else {
                        // Unexpected ESC in iTerm2 sequence
                        warn!("GraphicsInterceptor: Unexpected ESC {:02x} in iTerm2 sequence", byte);
                        self.iterm_args.clear();
                        self.iterm_data.clear();
                        self.state = State::Ground;
                    }
                }
            }
            i += 1;
        }

        (&self.passthrough, events)
    }

    // ── Event Emitters ───────────────────────────────────────────────

    fn emit_sixel(&mut self, events: &mut Vec<GraphicsEvent>) {
        let data = std::mem::take(&mut self.sixel_buf);
        let params = std::mem::take(&mut self.dcs_params);
        if !data.is_empty() {
            debug!("GraphicsInterceptor: Sixel complete ({} bytes, params={} bytes)",
                   data.len(), params.len());
            events.push(GraphicsEvent::Sixel { params, data });
        }
    }

    fn emit_kitty(&mut self, events: &mut Vec<GraphicsEvent>) {
        let control_bytes = std::mem::take(&mut self.kitty_control);
        let payload = std::mem::take(&mut self.kitty_payload);
        let control = String::from_utf8_lossy(&control_bytes).into_owned();
        debug!("GraphicsInterceptor: Kitty complete (control='{}', payload={} bytes)",
               control, payload.len());
        events.push(GraphicsEvent::Kitty { control, payload });
    }

    fn emit_iterm2(&mut self, events: &mut Vec<GraphicsEvent>) {
        let args_bytes = std::mem::take(&mut self.iterm_args);
        let base64_data = std::mem::take(&mut self.iterm_data);
        let args = String::from_utf8_lossy(&args_bytes).into_owned();
        debug!("GraphicsInterceptor: iTerm2 complete (args='{}', data={} bytes)",
               args, base64_data.len());
        events.push(GraphicsEvent::ITerm2 { args, base64_data });
    }

    /// Reset all state (e.g., on terminal reset).
    #[allow(dead_code)]
    pub fn reset(&mut self) {
        self.state = State::Ground;
        self.passthrough.clear();
        self.dcs_params.clear();
        self.sixel_buf.clear();
        self.kitty_control.clear();
        self.kitty_payload.clear();
        self.osc_prefix.clear();
        self.iterm_args.clear();
        self.iterm_data.clear();
    }
}

// ============================================================================
// Image Store — holds decoded images for FFI access
// ============================================================================

/// Thread-safe store for decoded images pending pickup by Swift.
pub struct ImageStore {
    /// Pending images not yet retrieved by Swift.
    pending: Vec<DecodedImage>,
    /// Monotonically increasing image ID counter.
    next_id: u64,
}

impl ImageStore {
    pub fn new() -> Self {
        Self {
            pending: Vec::new(),
            next_id: 1,
        }
    }

    /// Add a decoded image. Returns the assigned image ID.
    pub fn push(&mut self, mut image: DecodedImage) -> u64 {
        let id = self.next_id;
        self.next_id += 1;
        image.id = id;
        self.pending.push(image);
        id
    }

    /// Drain all pending images for FFI retrieval.
    pub fn take_pending(&mut self) -> Vec<DecodedImage> {
        std::mem::take(&mut self.pending)
    }

    /// Check if there are pending images.
    pub fn has_pending(&self) -> bool {
        !self.pending.is_empty()
    }
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_passthrough_normal_data() {
        let mut interceptor = GraphicsInterceptor::new();
        let input = b"Hello, world!\r\n";
        let (pass, events) = interceptor.feed(input);
        assert_eq!(pass, input.as_slice());
        assert!(events.is_empty());
    }

    #[test]
    fn test_passthrough_normal_escapes() {
        let mut interceptor = GraphicsInterceptor::new();
        // CSI sequence (not graphics)
        let input = b"\x1b[31mred\x1b[0m";
        let (pass, events) = interceptor.feed(input);
        assert_eq!(pass, input.as_slice());
        assert!(events.is_empty());
    }

    #[test]
    fn test_iterm2_extraction() {
        let mut interceptor = GraphicsInterceptor::new();
        // ESC ] 1337 ; File=inline=1: <base64> BEL
        let mut input = Vec::new();
        input.extend_from_slice(b"\x1b]1337;File=inline=1:");
        input.extend_from_slice(b"iVBORw0KGgo="); // tiny base64
        input.push(0x07); // BEL
        // Add some normal text after
        input.extend_from_slice(b"more text");

        let (pass, events) = interceptor.feed(&input);
        assert_eq!(pass, b"more text");
        assert_eq!(events.len(), 1);
        match &events[0] {
            GraphicsEvent::ITerm2 { args, base64_data } => {
                assert_eq!(args, "File=inline=1");
                assert_eq!(base64_data, b"iVBORw0KGgo=");
            }
            _ => panic!("Expected ITerm2 event"),
        }
    }

    #[test]
    fn test_iterm2_with_st_terminator() {
        let mut interceptor = GraphicsInterceptor::new();
        let mut input = Vec::new();
        input.extend_from_slice(b"\x1b]1337;File=inline=1:");
        input.extend_from_slice(b"AAAA");
        input.extend_from_slice(b"\x1b\\"); // ESC \ = ST

        let (pass, events) = interceptor.feed(&input);
        assert!(pass.is_empty());
        assert_eq!(events.len(), 1);
    }

    #[test]
    fn test_sixel_extraction() {
        let mut interceptor = GraphicsInterceptor::new();
        interceptor.sixel_enabled = true;

        // ESC P 0;1;q <sixel-data> ESC \
        let mut input = Vec::new();
        input.extend_from_slice(b"\x1bP0;1;q");
        input.extend_from_slice(b"#0;2;100;0;0~-~"); // minimal sixel
        input.extend_from_slice(b"\x1b\\"); // ST

        let (pass, events) = interceptor.feed(&input);
        assert!(pass.is_empty());
        assert_eq!(events.len(), 1);
        match &events[0] {
            GraphicsEvent::Sixel { params, data } => {
                assert_eq!(params, b"0;1;");
                assert!(!data.is_empty());
            }
            _ => panic!("Expected Sixel event"),
        }
    }

    #[test]
    fn test_sixel_disabled_passthrough() {
        let mut interceptor = GraphicsInterceptor::new();
        interceptor.sixel_enabled = false;

        let input = b"\x1bP0;1;q~\x1b\\";
        let (pass, events) = interceptor.feed(input);
        // Should pass through as-is when disabled
        assert!(!pass.is_empty());
        assert!(events.is_empty());
    }

    #[test]
    fn test_kitty_extraction() {
        let mut interceptor = GraphicsInterceptor::new();
        interceptor.kitty_enabled = true;

        // ESC _ G a=T,f=100,i=1; <base64> ESC \
        let mut input = Vec::new();
        input.extend_from_slice(b"\x1b_Ga=T,f=100,i=1;");
        input.extend_from_slice(b"iVBORw0KGgo=");
        input.extend_from_slice(b"\x1b\\");

        let (pass, events) = interceptor.feed(&input);
        assert!(pass.is_empty());
        assert_eq!(events.len(), 1);
        match &events[0] {
            GraphicsEvent::Kitty { control, payload } => {
                assert_eq!(control, "a=T,f=100,i=1");
                assert_eq!(payload, b"iVBORw0KGgo=");
            }
            _ => panic!("Expected Kitty event"),
        }
    }

    #[test]
    fn test_mixed_graphics_and_text() {
        let mut interceptor = GraphicsInterceptor::new();
        interceptor.sixel_enabled = true;

        let mut input = Vec::new();
        input.extend_from_slice(b"before");
        input.extend_from_slice(b"\x1b]1337;File=inline=1:AA\x07");
        input.extend_from_slice(b"between");
        input.extend_from_slice(b"\x1bP;q~~\x1b\\");
        input.extend_from_slice(b"after");

        let (pass, events) = interceptor.feed(&input);
        assert_eq!(pass, b"beforebetweenafter");
        assert_eq!(events.len(), 2);
    }

    #[test]
    fn test_split_across_feeds() {
        let mut interceptor = GraphicsInterceptor::new();

        // Split an iTerm2 sequence across two feed() calls
        let part1 = b"\x1b]1337;File=inline=1:AAAA";
        let part2 = b"BBBB\x07done";

        let (pass1, events1) = interceptor.feed(part1);
        assert!(pass1.is_empty()); // All buffered
        assert!(events1.is_empty()); // Not complete yet

        let (pass2, events2) = interceptor.feed(part2);
        assert_eq!(pass2, b"done");
        assert_eq!(events2.len(), 1);
        match &events2[0] {
            GraphicsEvent::ITerm2 { base64_data, .. } => {
                assert_eq!(base64_data, b"AAAABBBB");
            }
            _ => panic!("Expected ITerm2"),
        }
    }

    #[test]
    fn test_non_1337_osc_passthrough() {
        let mut interceptor = GraphicsInterceptor::new();
        // OSC 7 (directory) should pass through
        let input = b"\x1b]7;file:///tmp\x07rest";
        let (pass, events) = interceptor.feed(input);
        assert!(events.is_empty());
        // The pass-through should contain the original sequence
        assert!(pass.len() > 0);
    }
}
