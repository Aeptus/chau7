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
    ITerm2 { args: String, base64_data: Vec<u8> },
    /// Sixel image (DCS Pn;Pn;Pn q ... ST).
    /// Contains the raw sixel data bytes (everything after 'q' up to ST).
    Sixel { params: Vec<u8>, data: Vec<u8> },
    /// Kitty graphics protocol (ESC_G...ST).
    /// Contains the control key=value string and optional base64 payload.
    Kitty { control: String, payload: Vec<u8> },
}

/// FinalTerm/iTerm2 shell integration events (OSC 133).
///
/// These mark semantic zones in the terminal output so the host can
/// distinguish prompt, user input, and command output regions.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ShellIntegrationEvent {
    /// `A` — The shell is about to draw the prompt.
    PromptStart,
    /// `B` — The user pressed Enter; command line is complete.
    CommandStart,
    /// `C` — The command is now executing; output follows.
    CommandExecuted,
    /// `D` — The command finished. Carries the exit code (0 = success).
    CommandFinished { exit_code: i32 },
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
    /// Saw ESC ] — OSC sequence. Accumulating to check for "1337" or "133".
    Osc,
    /// Inside OSC 133 — accumulating the semantic marker (A/B/C/D and optional params).
    Osc133,
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
/// let (passthrough, events, shell) = interceptor.feed(pty_bytes);
/// processor.advance(&mut term, passthrough); // non-graphics to VTE
/// for event in events { handle_image(event); }
/// ```
pub struct GraphicsInterceptor {
    state: State,
    /// Buffer for non-graphics bytes to forward to VTE.
    passthrough: Vec<u8>,
    /// Spare passthrough buffer for zero-copy swap in `feed_owned()`.
    /// After `feed_owned()` takes the passthrough vec, this empty (but
    /// capacity-retaining) vec is swapped in, ready for the next call.
    passthrough_spare: Vec<u8>,
    /// Accumulator for DCS parameters (before the 'q' final char).
    dcs_params: Vec<u8>,
    /// Accumulator for Sixel data bytes.
    sixel_buf: Vec<u8>,
    /// Accumulator for Kitty control string (key=value pairs).
    kitty_control: Vec<u8>,
    /// Accumulator for Kitty base64 payload.
    kitty_payload: Vec<u8>,
    /// Accumulator for OSC prefix (to match "1337" or "133").
    osc_prefix: Vec<u8>,
    /// Accumulator for OSC 133 body (marker + optional params after ';').
    osc133_buf: Vec<u8>,
    /// Accumulator for iTerm2 args (between "File=" and ":").
    iterm_args: Vec<u8>,
    /// Accumulator for iTerm2 base64 data (after ":").
    iterm_data: Vec<u8>,
    /// Shell integration events extracted this feed cycle.
    shell_events: Vec<ShellIntegrationEvent>,
    /// Whether each protocol is enabled.
    pub sixel_enabled: bool,
    pub kitty_enabled: bool,
    pub iterm2_enabled: bool,
}

impl Default for GraphicsInterceptor {
    fn default() -> Self {
        Self::new()
    }
}

impl GraphicsInterceptor {
    pub fn new() -> Self {
        Self {
            state: State::Ground,
            passthrough: Vec::with_capacity(4096),
            passthrough_spare: Vec::with_capacity(4096),
            dcs_params: Vec::new(),
            sixel_buf: Vec::new(),
            kitty_control: Vec::new(),
            kitty_payload: Vec::new(),
            osc_prefix: Vec::new(),
            osc133_buf: Vec::new(),
            iterm_args: Vec::new(),
            iterm_data: Vec::new(),
            shell_events: Vec::new(),
            sixel_enabled: true,
            kitty_enabled: true,
            iterm2_enabled: true, // iTerm2 on by default
        }
    }

    /// Feed raw PTY bytes through the interceptor.
    ///
    /// Returns a slice of passthrough bytes (forward to VTE), a vec of
    /// extracted graphics events, and a vec of shell integration events (OSC 133).
    pub fn feed<'a>(
        &'a mut self,
        input: &[u8],
    ) -> (&'a [u8], Vec<GraphicsEvent>, Vec<ShellIntegrationEvent>) {
        self.passthrough.clear();
        self.shell_events.clear();
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
                            self.passthrough
                                .extend_from_slice(&input[i..i + esc_offset]);
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
                    // ESC ] → OSC (potential iTerm2 image or OSC 133 shell integration)
                    0x5D => {
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
                    } else if self.sixel_buf.len() < SIXEL_MAX_BYTES {
                        self.sixel_buf.push(byte);
                    } else {
                        warn!(
                            "GraphicsInterceptor: Sixel data exceeded {}MB, discarding",
                            SIXEL_MAX_BYTES / (1024 * 1024)
                        );
                        self.sixel_buf.clear();
                        self.dcs_params.clear();
                        self.state = State::Ground;
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
                    } else if self.kitty_payload.len() < KITTY_MAX_BYTES {
                        self.kitty_payload.push(byte);
                    } else {
                        warn!("GraphicsInterceptor: Kitty payload exceeded limit, discarding");
                        self.kitty_control.clear();
                        self.kitty_payload.clear();
                        self.state = State::Ground;
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
                        warn!(
                            "GraphicsInterceptor: Unexpected ESC {:02x} in Kitty sequence",
                            byte
                        );
                        self.kitty_control.clear();
                        self.kitty_payload.clear();
                        self.state = State::Ground;
                    }
                }

                // ── OSC / iTerm2 / Shell Integration ────────────────
                State::Osc => {
                    if byte == b';' {
                        if self.iterm2_enabled && self.osc_prefix == b"1337" {
                            // OSC 1337 → iTerm2 image
                            self.iterm_args.clear();
                            self.iterm_data.clear();
                            self.state = State::ITermArgs;
                            trace!("GraphicsInterceptor: iTerm2 OSC 1337 sequence started");
                        } else if self.osc_prefix == b"133" {
                            // OSC 133 → FinalTerm shell integration
                            self.osc133_buf.clear();
                            self.state = State::Osc133;
                            trace!("GraphicsInterceptor: OSC 133 shell integration sequence");
                        } else {
                            // Not a sequence we intercept — pass through
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
                        // For non-intercepted OSC, just pass through
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

                // ── OSC 133 body ────────────────────────────────────
                State::Osc133 => {
                    if byte == 0x07 || byte == 0x9C {
                        // BEL or 8-bit ST — sequence complete
                        self.emit_osc133();
                        self.state = State::Ground;
                    } else if byte == 0x1B {
                        // Potential ESC \ (ST) — peek at next byte
                        // We need to handle this carefully: if the next byte
                        // is '\', it's the ST terminator. But we can't peek
                        // from here, so push a sentinel and check in the loop.
                        // Actually, use the same trick as the other states:
                        // temporarily save that we saw ESC, handle in next iteration.
                        // For simplicity, just treat ESC as terminator here
                        // since OSC 133 bodies are very short (1-5 bytes).
                        self.emit_osc133();
                        // Pass the ESC through so VTE can handle ESC \ if needed
                        self.passthrough.push(0x1B);
                        self.state = State::Ground;
                    } else if self.osc133_buf.len() < 32 {
                        self.osc133_buf.push(byte);
                    } else {
                        // Too long for OSC 133 — discard
                        warn!("GraphicsInterceptor: OSC 133 body too long, discarding");
                        self.osc133_buf.clear();
                        self.state = State::Ground;
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
                    } else if self.iterm_data.len() < ITERM2_MAX_BYTES {
                        self.iterm_data.push(byte);
                    } else {
                        warn!("GraphicsInterceptor: iTerm2 data exceeded limit, discarding");
                        self.iterm_args.clear();
                        self.iterm_data.clear();
                        self.state = State::Ground;
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
                        warn!(
                            "GraphicsInterceptor: Unexpected ESC {:02x} in iTerm2 sequence",
                            byte
                        );
                        self.iterm_args.clear();
                        self.iterm_data.clear();
                        self.state = State::Ground;
                    }
                }
            }
            i += 1;
        }

        let shell = std::mem::take(&mut self.shell_events);
        (&self.passthrough, events, shell)
    }

    /// Feed raw PTY bytes and return an **owned** passthrough vec (zero-copy).
    ///
    /// Unlike `feed()`, this swaps the internal passthrough buffer out instead
    /// of returning a borrow. This lets the caller drop the interceptor lock
    /// before processing the passthrough bytes — avoiding the `.to_vec()` copy
    /// that `feed()` + borrow requires when locks must be released in between.
    ///
    /// The spare buffer (with retained capacity) is swapped in so the next
    /// call doesn't need to allocate.
    pub fn feed_owned(
        &mut self,
        input: &[u8],
    ) -> (Vec<u8>, Vec<GraphicsEvent>, Vec<ShellIntegrationEvent>) {
        // Run feed() which populates self.passthrough and returns events.
        // We deliberately ignore the returned borrow (&[u8]) — we'll swap
        // the vec out instead.
        let (events, shell_events) = {
            let (_borrow, events, shell) = self.feed(input);
            (events, shell)
            // _borrow (reference to self.passthrough) is dropped here
        };
        // Now self is exclusively borrowed again — safe to swap.
        // Swap passthrough out, put the spare (empty but allocated) in its place.
        // This is just 3 pointer swaps — no allocation, no memcpy.
        std::mem::swap(&mut self.passthrough, &mut self.passthrough_spare);
        // passthrough_spare now holds the data; passthrough is the old spare (empty).
        let owned = std::mem::take(&mut self.passthrough_spare);
        (owned, events, shell_events)
    }

    // ── Event Emitters ───────────────────────────────────────────────

    fn emit_sixel(&mut self, events: &mut Vec<GraphicsEvent>) {
        let data = std::mem::take(&mut self.sixel_buf);
        let params = std::mem::take(&mut self.dcs_params);
        if !data.is_empty() {
            debug!(
                "GraphicsInterceptor: Sixel complete ({} bytes, params={} bytes)",
                data.len(),
                params.len()
            );
            events.push(GraphicsEvent::Sixel { params, data });
        }
    }

    fn emit_kitty(&mut self, events: &mut Vec<GraphicsEvent>) {
        let control_bytes = std::mem::take(&mut self.kitty_control);
        let payload = std::mem::take(&mut self.kitty_payload);
        let control = String::from_utf8_lossy(&control_bytes).into_owned();
        debug!(
            "GraphicsInterceptor: Kitty complete (control='{}', payload={} bytes)",
            control,
            payload.len()
        );
        events.push(GraphicsEvent::Kitty { control, payload });
    }

    fn emit_iterm2(&mut self, events: &mut Vec<GraphicsEvent>) {
        let args_bytes = std::mem::take(&mut self.iterm_args);
        let base64_data = std::mem::take(&mut self.iterm_data);
        let args = String::from_utf8_lossy(&args_bytes).into_owned();
        debug!(
            "GraphicsInterceptor: iTerm2 complete (args='{}', data={} bytes)",
            args,
            base64_data.len()
        );
        events.push(GraphicsEvent::ITerm2 { args, base64_data });
    }

    /// Parse OSC 133 body and push a ShellIntegrationEvent.
    /// Body format: `A`, `B`, `C`, or `D;exitcode` (plus optional extra params we ignore).
    fn emit_osc133(&mut self) {
        let body = std::mem::take(&mut self.osc133_buf);
        if body.is_empty() {
            return;
        }

        let event = match body[0] {
            b'A' => ShellIntegrationEvent::PromptStart,
            b'B' => ShellIntegrationEvent::CommandStart,
            b'C' => ShellIntegrationEvent::CommandExecuted,
            b'D' => {
                // D may be followed by ;exitcode (e.g., "D;0" or "D;1")
                let exit_code = if body.len() > 2 && body[1] == b';' {
                    std::str::from_utf8(&body[2..])
                        .ok()
                        .and_then(|s| s.parse::<i32>().ok())
                        .unwrap_or(0)
                } else {
                    0
                };
                ShellIntegrationEvent::CommandFinished { exit_code }
            }
            _ => {
                debug!(
                    "GraphicsInterceptor: unknown OSC 133 marker: {:?}",
                    String::from_utf8_lossy(&body)
                );
                return;
            }
        };

        debug!("GraphicsInterceptor: OSC 133 {:?}", event);
        self.shell_events.push(event);
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
// Sixel Decoder
// ============================================================================

/// Maximum image dimensions to prevent OOM from malicious input.
const SIXEL_MAX_WIDTH: u32 = 4096;
const SIXEL_MAX_HEIGHT: u32 = 4096;

/// Decode Sixel image data into RGBA pixels.
///
/// Input format: The raw DCS data AFTER the 'q' introducer character.
/// Sixel encodes images as columns of 6 pixels. Each character in the range
/// '?' (63) to '~' (126) represents a 6-bit pattern where each bit controls
/// one pixel vertically (bit 0 = top pixel, bit 5 = bottom pixel).
///
/// Returns (rgba_data, width, height) or None if decoding fails.
pub fn decode_sixel(data: &[u8]) -> Option<(Vec<u8>, u32, u32)> {
    // Color registers (0-255), each stores (r, g, b) in 0-255 range
    let mut colors: Vec<(u8, u8, u8)> = vec![(0, 0, 0); 256];
    // Default color 0 to white
    colors[0] = (255, 255, 255);

    let mut current_color: usize = 0;
    let mut x: u32 = 0;
    let mut y: u32 = 0; // Top of current 6-pixel band
    let mut max_x: u32 = 0;

    // Single-pass decode: pixel rows grown on demand.
    // Each entry is one pixel row's RGBA data (variable length).
    let mut rows: Vec<Vec<u8>> = Vec::new();

    let mut i = 0;
    while i < data.len() {
        let b = data[i];
        match b {
            b'$' => {
                // Graphics carriage return
                if x > max_x {
                    max_x = x;
                }
                x = 0;
            }
            b'-' => {
                // Graphics new line
                if x > max_x {
                    max_x = x;
                }
                x = 0;
                y += 6;
                if y >= SIXEL_MAX_HEIGHT {
                    warn!("Sixel decode: height exceeds max {}", SIXEL_MAX_HEIGHT);
                    return None;
                }
            }
            b'!' => {
                // Repeat: !<count><sixel_char>
                i += 1;
                let mut count: u32 = 0;
                while i < data.len() && data[i].is_ascii_digit() {
                    count = count
                        .saturating_mul(10)
                        .saturating_add((data[i] - b'0') as u32);
                    i += 1;
                }
                if i < data.len() && data[i] >= 0x3F && data[i] <= 0x7E {
                    let bits = data[i] - 0x3F;
                    let (r, g, b_color) = colors[current_color];
                    // Cap repeat count to prevent unbounded iteration
                    let effective_count = count.min(SIXEL_MAX_WIDTH.saturating_sub(x));
                    for _ in 0..effective_count {
                        paint_sixel_rows(&mut rows, x, y, bits, r, g, b_color);
                        x += 1;
                    }
                }
            }
            b'#' => {
                // Color introducer: #<reg> or #<reg>;<type>;<v1>;<v2>;<v3>
                i += 1;
                let mut reg: usize = 0;
                while i < data.len() && data[i].is_ascii_digit() {
                    reg = reg
                        .saturating_mul(10)
                        .saturating_add((data[i] - b'0') as usize);
                    i += 1;
                }
                if reg >= 256 {
                    reg = 0;
                }

                if i < data.len() && data[i] == b';' {
                    // Color definition: ;type;v1;v2;v3
                    i += 1;
                    let mut params = [0u32; 4];
                    let mut pi = 0;
                    while i < data.len() && pi < 4 {
                        if data[i].is_ascii_digit() {
                            params[pi] = params[pi] * 10 + (data[i] - b'0') as u32;
                        } else if data[i] == b';' {
                            pi += 1;
                        } else {
                            break;
                        }
                        i += 1;
                    }
                    let color_type = params[0];
                    if color_type == 2 {
                        // RGB: values are 0-100 percentages
                        let r = ((params[1].min(100) * 255 + 50) / 100) as u8;
                        let g = ((params[2].min(100) * 255 + 50) / 100) as u8;
                        let b_val = ((params[3].min(100) * 255 + 50) / 100) as u8;
                        colors[reg] = (r, g, b_val);
                    } else if color_type == 1 {
                        // HLS: convert to RGB
                        let h = params[1] % 360;
                        let l = params[2].min(100);
                        let s = params[3].min(100);
                        let (r, g, b_val) = hls_to_rgb(h, l, s);
                        colors[reg] = (r, g, b_val);
                    }
                    current_color = reg;
                    continue; // Don't increment i
                }
                current_color = reg;
                continue; // Don't increment i
            }
            b'"' => {
                // Raster attributes — skip
                i += 1;
                while i < data.len() && (data[i].is_ascii_digit() || data[i] == b';') {
                    i += 1;
                }
                continue;
            }
            0x3F..=0x7E => {
                // Sixel data character
                let bits = b - 0x3F;
                let (r, g, b_color) = colors[current_color];
                if x < SIXEL_MAX_WIDTH {
                    paint_sixel_rows(&mut rows, x, y, bits, r, g, b_color);
                    x += 1;
                }
            }
            _ => {
                // Ignore unknown bytes
            }
        }
        i += 1;
    }
    if x > max_x {
        max_x = x;
    }

    let width = max_x;
    // Last band always extends 6 pixel rows per the sixel spec
    let height = y.saturating_add(6);

    if width == 0 || height == 0 || height < y {
        warn!("Sixel decode: empty image ({}x{})", width, height);
        return None;
    }
    if width > SIXEL_MAX_WIDTH || height > SIXEL_MAX_HEIGHT {
        warn!(
            "Sixel decode: image too large ({}x{}, max {}x{})",
            width, height, SIXEL_MAX_WIDTH, SIXEL_MAX_HEIGHT
        );
        return None;
    }

    debug!(
        "Sixel decode: {}x{} image, {} bytes of data",
        width,
        height,
        data.len()
    );

    // Flatten rows into contiguous RGBA buffer
    let mut rgba = vec![0u8; (width as usize) * (height as usize) * 4];
    let row_stride = (width as usize) * 4;
    for row_idx in 0..height as usize {
        if let Some(row) = rows.get(row_idx) {
            let copy_len = row.len().min(row_stride);
            let dst = row_idx * row_stride;
            rgba[dst..dst + copy_len].copy_from_slice(&row[..copy_len]);
        }
    }

    Some((rgba, width, height))
}

/// Paint a single sixel column (6 vertical pixels) into row-based RGBA buffers.
#[inline]
fn paint_sixel_rows(rows: &mut Vec<Vec<u8>>, x: u32, band_y: u32, bits: u8, r: u8, g: u8, b: u8) {
    for bit in 0..6u32 {
        if bits & (1 << bit) != 0 {
            let py = band_y + bit;
            if py >= SIXEL_MAX_HEIGHT {
                break;
            }
            let py_idx = py as usize;
            // Grow row list if needed
            if rows.len() <= py_idx {
                rows.resize_with(py_idx + 1, Vec::new);
            }
            // Grow row width if needed
            let needed = ((x as usize) + 1) * 4;
            let row = &mut rows[py_idx];
            if row.len() < needed {
                row.resize(needed, 0);
            }
            let offset = (x as usize) * 4;
            row[offset] = r;
            row[offset + 1] = g;
            row[offset + 2] = b;
            row[offset + 3] = 255;
        }
    }
}

/// Convert HLS (Hue 0-360, Lightness 0-100, Saturation 0-100) to RGB (0-255).
fn hls_to_rgb(h: u32, l: u32, s: u32) -> (u8, u8, u8) {
    if s == 0 {
        let v = ((l * 255 + 50) / 100) as u8;
        return (v, v, v);
    }
    let l_f = l as f64 / 100.0;
    let s_f = s as f64 / 100.0;
    let h_f = h as f64 / 360.0;

    let q = if l_f < 0.5 {
        l_f * (1.0 + s_f)
    } else {
        l_f + s_f - l_f * s_f
    };
    let p = 2.0 * l_f - q;

    let r = hue_to_rgb(p, q, h_f + 1.0 / 3.0);
    let g = hue_to_rgb(p, q, h_f);
    let b = hue_to_rgb(p, q, h_f - 1.0 / 3.0);

    ((r * 255.0) as u8, (g * 255.0) as u8, (b * 255.0) as u8)
}

fn hue_to_rgb(p: f64, q: f64, mut t: f64) -> f64 {
    if t < 0.0 {
        t += 1.0;
    }
    if t > 1.0 {
        t -= 1.0;
    }
    if t < 1.0 / 6.0 {
        return p + (q - p) * 6.0 * t;
    }
    if t < 1.0 / 2.0 {
        return q;
    }
    if t < 2.0 / 3.0 {
        return p + (q - p) * (2.0 / 3.0 - t) * 6.0;
    }
    p
}

// ============================================================================
// Kitty Graphics Protocol Decoder
// ============================================================================

/// Result of processing a Kitty graphics command.
#[derive(Debug)]
pub enum KittyAction {
    /// Image ready for display.
    Display {
        rgba: Vec<u8>,
        width: u32,
        height: u32,
    },
    /// More chunks expected — accumulating.
    Continue,
    /// Delete an image by ID (0 = all).
    #[allow(dead_code)]
    Delete { id: u32 },
    /// Nothing to do (query, unsupported action, etc.).
    Noop,
}

/// Accumulator for multi-chunk Kitty transmissions.
pub struct KittyAccumulator {
    /// Base64 payload accumulated across chunks.
    payload: Vec<u8>,
    /// Control string from the first chunk (defines format, dimensions, etc.).
    control: String,
}

impl Default for KittyAccumulator {
    fn default() -> Self {
        Self::new()
    }
}

impl KittyAccumulator {
    pub fn new() -> Self {
        Self {
            payload: Vec::new(),
            control: String::new(),
        }
    }

    /// Feed a Kitty graphics command. Returns the action to take.
    ///
    /// Handles multi-chunk (`m=1`) accumulation: intermediate chunks return
    /// `KittyAction::Continue`, the final chunk (`m=0` or absent) returns
    /// `KittyAction::Display` with decoded RGBA data.
    pub fn feed(&mut self, control: &str, payload: &[u8]) -> KittyAction {
        let params = parse_kitty_control(control);

        let action = params.get("a").unwrap_or("T");
        let more = params.get("m").unwrap_or("0");

        match action {
            "T" | "t" => {
                // Transmit (and optionally display)
                if self.payload.is_empty() {
                    // First chunk — store control string
                    self.control = control.to_string();
                }
                self.payload.extend_from_slice(payload);

                if more == "1" {
                    // More chunks coming
                    return KittyAction::Continue;
                }

                // Final chunk — decode
                let result = self.decode_payload();
                self.payload.clear();
                self.control.clear();
                result
            }
            "d" => {
                // Delete
                let id = params.get("i").and_then(|s| s.parse().ok()).unwrap_or(0u32);
                self.payload.clear();
                self.control.clear();
                KittyAction::Delete { id }
            }
            "q" => {
                // Query — we don't respond to queries yet
                self.payload.clear();
                self.control.clear();
                KittyAction::Noop
            }
            _ => {
                self.payload.clear();
                self.control.clear();
                KittyAction::Noop
            }
        }
    }

    /// Decode the accumulated payload into RGBA pixels.
    fn decode_payload(&self) -> KittyAction {
        // Parse the stored control string (always from the first chunk)
        let params = parse_kitty_control(&self.control);

        let format = params
            .get("f")
            .and_then(|s| s.parse().ok())
            .unwrap_or(32u32);
        let transmission = params.get("t").unwrap_or("d");

        if transmission != "d" {
            // Only direct transmission supported for now (no file/shared memory)
            warn!("Kitty: unsupported transmission type '{}'", transmission);
            return KittyAction::Noop;
        }

        // Decode base64 payload
        use base64::Engine;
        let raw = match base64::engine::general_purpose::STANDARD.decode(&self.payload) {
            Ok(data) => data,
            Err(e) => {
                warn!("Kitty: base64 decode failed: {}", e);
                return KittyAction::Noop;
            }
        };

        match format {
            24 => {
                // Raw RGB (3 bytes per pixel)
                let width = params.get("s").and_then(|s| s.parse().ok()).unwrap_or(0u32);
                let height = params.get("v").and_then(|s| s.parse().ok()).unwrap_or(0u32);
                if width == 0 || height == 0 {
                    warn!("Kitty: RGB format requires s= and v= dimensions");
                    return KittyAction::Noop;
                }
                let expected = (width * height * 3) as usize;
                if raw.len() < expected {
                    warn!("Kitty: RGB data too short ({} < {})", raw.len(), expected);
                    return KittyAction::Noop;
                }
                // Convert RGB → RGBA
                let pixel_count = (width * height) as usize;
                let mut rgba = Vec::with_capacity(pixel_count * 4);
                for i in 0..pixel_count {
                    rgba.push(raw[i * 3]);
                    rgba.push(raw[i * 3 + 1]);
                    rgba.push(raw[i * 3 + 2]);
                    rgba.push(255);
                }
                KittyAction::Display {
                    rgba,
                    width,
                    height,
                }
            }
            32 => {
                // Raw RGBA (4 bytes per pixel)
                let width = params.get("s").and_then(|s| s.parse().ok()).unwrap_or(0u32);
                let height = params.get("v").and_then(|s| s.parse().ok()).unwrap_or(0u32);
                if width == 0 || height == 0 {
                    warn!("Kitty: RGBA format requires s= and v= dimensions");
                    return KittyAction::Noop;
                }
                let expected = (width * height * 4) as usize;
                if raw.len() < expected {
                    warn!("Kitty: RGBA data too short ({} < {})", raw.len(), expected);
                    return KittyAction::Noop;
                }
                let rgba = raw[..expected].to_vec();
                KittyAction::Display {
                    rgba,
                    width,
                    height,
                }
            }
            100 => {
                // PNG — decode to get dimensions and RGBA
                decode_kitty_png(&raw)
            }
            _ => {
                warn!("Kitty: unsupported format f={}", format);
                KittyAction::Noop
            }
        }
    }

    /// Reset the accumulator (e.g., on error or terminal reset).
    #[allow(dead_code)]
    pub fn reset(&mut self) {
        self.payload.clear();
        self.control.clear();
    }
}

/// Parsed Kitty control parameters — avoids HashMap allocation.
/// Stores up to 16 key-value pairs inline with borrowed string slices.
struct KittyParams<'a> {
    pairs: [(&'a str, &'a str); 16],
    len: usize,
}

impl<'a> KittyParams<'a> {
    fn get(&self, key: &str) -> Option<&'a str> {
        for i in 0..self.len {
            if self.pairs[i].0 == key {
                return Some(self.pairs[i].1);
            }
        }
        None
    }
}

/// Parse Kitty control string "key=val,key2=val2" into inline params.
fn parse_kitty_control(control: &str) -> KittyParams<'_> {
    let mut params = KittyParams {
        pairs: [("", ""); 16],
        len: 0,
    };
    for pair in control.split(',') {
        if let Some((key, val)) = pair.split_once('=')
            && params.len < 16
        {
            params.pairs[params.len] = (key, val);
            params.len += 1;
        }
    }
    params
}

/// Decode a PNG buffer into RGBA pixels using minimal PNG parsing.
/// We read the IHDR chunk for dimensions and decode via the `image` crate
/// if available, or fall back to a minimal approach.
fn decode_kitty_png(data: &[u8]) -> KittyAction {
    // Minimal PNG dimension extraction from IHDR chunk:
    // PNG signature (8 bytes) + IHDR length (4 bytes) + "IHDR" (4 bytes) + width (4 BE) + height (4 BE)
    if data.len() < 24 {
        warn!("Kitty PNG: data too short for PNG header");
        return KittyAction::Noop;
    }

    // Verify PNG signature
    if &data[0..8] != b"\x89PNG\r\n\x1a\n" {
        warn!("Kitty PNG: invalid PNG signature");
        return KittyAction::Noop;
    }

    let width = u32::from_be_bytes([data[16], data[17], data[18], data[19]]);
    let height = u32::from_be_bytes([data[20], data[21], data[22], data[23]]);

    if width == 0 || height == 0 || width > 4096 || height > 4096 {
        warn!("Kitty PNG: invalid dimensions {}x{}", width, height);
        return KittyAction::Noop;
    }

    // For now, store the raw PNG data as the "rgba" field and let Swift decode it.
    // Swift's NSImage can handle PNG natively, which is more efficient than
    // adding the `image` crate dependency to Rust.
    // We mark width/height so Swift knows the image dimensions.
    debug!("Kitty PNG: {}x{}, {} bytes", width, height, data.len());
    KittyAction::Display {
        rgba: data.to_vec(),
        width,
        height,
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

impl Default for ImageStore {
    fn default() -> Self {
        Self::new()
    }
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
        let (pass, events, _shell) = interceptor.feed(input);
        assert_eq!(pass, input.as_slice());
        assert!(events.is_empty());
    }

    #[test]
    fn test_passthrough_normal_escapes() {
        let mut interceptor = GraphicsInterceptor::new();
        // CSI sequence (not graphics)
        let input = b"\x1b[31mred\x1b[0m";
        let (pass, events, _shell) = interceptor.feed(input);
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

        let (pass, events, _shell) = interceptor.feed(&input);
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

        let (pass, events, _shell) = interceptor.feed(&input);
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

        let (pass, events, _shell) = interceptor.feed(&input);
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
        let (pass, events, _shell) = interceptor.feed(input);
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

        let (pass, events, _shell) = interceptor.feed(&input);
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

        let (pass, events, _shell) = interceptor.feed(&input);
        assert_eq!(pass, b"beforebetweenafter");
        assert_eq!(events.len(), 2);
    }

    #[test]
    fn test_split_across_feeds() {
        let mut interceptor = GraphicsInterceptor::new();

        // Split an iTerm2 sequence across two feed() calls
        let part1 = b"\x1b]1337;File=inline=1:AAAA";
        let part2 = b"BBBB\x07done";

        let (pass1, events1, _shell1) = interceptor.feed(part1);
        assert!(pass1.is_empty()); // All buffered
        assert!(events1.is_empty()); // Not complete yet

        let (pass2, events2, _shell2) = interceptor.feed(part2);
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
        let (pass, events, _shell) = interceptor.feed(input);
        assert!(events.is_empty());
        // The pass-through should contain the original sequence
        assert!(!pass.is_empty());
    }

    // ── OSC 133 (shell integration) tests ─────────────────────────────

    #[test]
    fn test_osc133_prompt_start() {
        let mut interceptor = GraphicsInterceptor::new();
        // ESC ] 133 ; A BEL
        let input = b"\x1b]133;A\x07";
        let (pass, events, shell) = interceptor.feed(input);
        assert!(events.is_empty());
        assert!(pass.is_empty()); // OSC 133 is consumed, not passed through
        assert_eq!(shell.len(), 1);
        assert_eq!(shell[0], ShellIntegrationEvent::PromptStart);
    }

    #[test]
    fn test_osc133_command_finished_with_exit_code() {
        let mut interceptor = GraphicsInterceptor::new();
        // ESC ] 133 ; D ; 1 BEL (exit code 1)
        let input = b"\x1b]133;D;1\x07";
        let (_pass, _events, shell) = interceptor.feed(input);
        assert_eq!(shell.len(), 1);
        assert_eq!(
            shell[0],
            ShellIntegrationEvent::CommandFinished { exit_code: 1 }
        );
    }

    #[test]
    fn test_osc133_full_lifecycle() {
        let mut interceptor = GraphicsInterceptor::new();
        // Simulate a full prompt → command → output → finish cycle with surrounding text
        let input = b"some text\x1b]133;A\x07prompt$ \x1b]133;B\x07\x1b]133;C\x07output\x1b]133;D;0\x07";
        let (pass, events, shell) = interceptor.feed(input);
        assert!(events.is_empty());
        assert_eq!(shell.len(), 4);
        assert_eq!(shell[0], ShellIntegrationEvent::PromptStart);
        assert_eq!(shell[1], ShellIntegrationEvent::CommandStart);
        assert_eq!(shell[2], ShellIntegrationEvent::CommandExecuted);
        assert_eq!(
            shell[3],
            ShellIntegrationEvent::CommandFinished { exit_code: 0 }
        );
        // "some text", "prompt$ ", and "output" should pass through
        let pass_str = std::str::from_utf8(pass).unwrap();
        assert!(pass_str.contains("some text"));
        assert!(pass_str.contains("prompt$ "));
        assert!(pass_str.contains("output"));
    }

    #[test]
    fn test_osc133_with_st_terminator() {
        let mut interceptor = GraphicsInterceptor::new();
        // ESC ] 133 ; B ESC \ (using ST instead of BEL)
        let input = b"\x1b]133;B\x1b\\";
        let (_pass, _events, shell) = interceptor.feed(input);
        assert_eq!(shell.len(), 1);
        assert_eq!(shell[0], ShellIntegrationEvent::CommandStart);
    }

    // ── Sixel decoder tests ──────────────────────────────────────────

    #[test]
    fn test_sixel_decode_single_red_pixel() {
        // A single red pixel: color 0 = 100% red, one sixel char '?' + bit0 = '@'
        // '#0;2;100;0;0' defines color 0 as red, '@' = 0x40 - 0x3F = 1 = bit 0 set
        let data = b"#0;2;100;0;0@";
        let result = decode_sixel(data);
        assert!(result.is_some(), "Should decode successfully");
        let (rgba, width, height) = result.unwrap();
        assert_eq!(width, 1);
        assert_eq!(height, 6); // Always 6 pixels per band
        assert_eq!(rgba.len(), 6 * 4);
        // First pixel should be red (R=255, G=0, B=0, A=255)
        assert_eq!(rgba[0], 255); // R
        assert_eq!(rgba[1], 0); // G
        assert_eq!(rgba[2], 0); // B
        assert_eq!(rgba[3], 255); // A
    }

    #[test]
    fn test_sixel_decode_repeat() {
        // 3 red pixels using repeat: !3@
        let data = b"#0;2;100;0;0!3@";
        let result = decode_sixel(data);
        assert!(result.is_some());
        let (rgba, width, height) = result.unwrap();
        assert_eq!(width, 3);
        assert_eq!(height, 6);
        // All 3 top pixels should be red
        for col in 0..3 {
            let offset = col * 4;
            assert_eq!(rgba[offset], 255, "Pixel {} R", col);
            assert_eq!(rgba[offset + 3], 255, "Pixel {} A", col);
        }
    }

    #[test]
    fn test_sixel_decode_multiband() {
        // Two bands: '@' on first band, '-' (newline), '@' on second band
        let data = b"#0;2;100;0;0@-@";
        let result = decode_sixel(data);
        assert!(result.is_some());
        let (rgba, width, height) = result.unwrap();
        assert_eq!(width, 1);
        assert_eq!(height, 12); // Two 6-pixel bands
        // Pixel at (0, 0) should be red
        assert_eq!(rgba[0], 255);
        assert_eq!(rgba[3], 255);
        // Pixel at (0, 6) should be red (second band, first pixel)
        let offset = 6 * 4; // row 6, col 0
        assert_eq!(rgba[offset], 255);
        assert_eq!(rgba[offset + 3], 255);
    }

    #[test]
    fn test_sixel_decode_hls_color() {
        // HLS color: type=1, H=0 (red), L=50, S=100
        let data = b"#0;1;0;50;100@";
        let result = decode_sixel(data);
        assert!(result.is_some());
        let (rgba, _, _) = result.unwrap();
        // Should produce a reddish pixel (HLS 0,50,100 → approximately red)
        assert!(rgba[0] > 200, "R should be high: {}", rgba[0]);
        assert_eq!(rgba[3], 255); // A
    }

    #[test]
    fn test_sixel_decode_empty() {
        let data = b"";
        let result = decode_sixel(data);
        assert!(result.is_none(), "Empty data should return None");
    }

    #[test]
    fn test_sixel_decode_multiple_colors() {
        // Two colors: red and blue, drawn side by side
        let data = b"#0;2;100;0;0#1;2;0;0;100#0@#1@";
        let result = decode_sixel(data);
        assert!(result.is_some());
        let (rgba, width, _) = result.unwrap();
        assert_eq!(width, 2);
        // Pixel (0,0) = red
        assert_eq!(rgba[0], 255); // R
        assert_eq!(rgba[1], 0); // G
        assert_eq!(rgba[2], 0); // B
        // Pixel (1,0) = blue
        assert_eq!(rgba[4], 0); // R
        assert_eq!(rgba[5], 0); // G
        assert_eq!(rgba[6], 255); // B
    }

    #[test]
    fn test_sixel_decode_carriage_return() {
        // '$' = graphics CR — returns to start of band for overpainting
        // Draw red at x=0, then '$' to go back, then blue at x=0 (overwrites red)
        let data = b"#0;2;100;0;0@$#1;2;0;0;100@";
        let result = decode_sixel(data);
        assert!(result.is_some());
        let (rgba, width, _) = result.unwrap();
        assert_eq!(width, 1);
        // Pixel (0,0) should be blue (overwritten)
        assert_eq!(rgba[0], 0); // R
        assert_eq!(rgba[1], 0); // G
        assert_eq!(rgba[2], 255); // B
    }

    // ── Kitty decoder tests ──────────────────────────────────────────

    #[test]
    fn test_kitty_rgba_direct() {
        use base64::Engine;
        let mut accum = KittyAccumulator::new();
        // 2x2 red RGBA pixels
        let pixels: Vec<u8> = vec![
            255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255,
        ];
        let b64 = base64::engine::general_purpose::STANDARD.encode(&pixels);
        let control = "a=T,f=32,s=2,v=2";
        match accum.feed(control, b64.as_bytes()) {
            KittyAction::Display {
                rgba,
                width,
                height,
            } => {
                assert_eq!(width, 2);
                assert_eq!(height, 2);
                assert_eq!(rgba.len(), 16);
                assert_eq!(rgba[0], 255); // R
                assert_eq!(rgba[3], 255); // A
            }
            other => panic!("Expected Display, got {:?}", other),
        }
    }

    #[test]
    fn test_kitty_rgb_direct() {
        use base64::Engine;
        let mut accum = KittyAccumulator::new();
        // 2x1 green RGB pixels
        let pixels: Vec<u8> = vec![0, 255, 0, 0, 255, 0];
        let b64 = base64::engine::general_purpose::STANDARD.encode(&pixels);
        let control = "a=T,f=24,s=2,v=1";
        match accum.feed(control, b64.as_bytes()) {
            KittyAction::Display {
                rgba,
                width,
                height,
            } => {
                assert_eq!(width, 2);
                assert_eq!(height, 1);
                assert_eq!(rgba.len(), 8); // 2 pixels * 4 bytes RGBA
                // First pixel: R=0, G=255, B=0, A=255
                assert_eq!(rgba[0], 0);
                assert_eq!(rgba[1], 255);
                assert_eq!(rgba[2], 0);
                assert_eq!(rgba[3], 255);
            }
            other => panic!("Expected Display, got {:?}", other),
        }
    }

    #[test]
    fn test_kitty_multichunk() {
        use base64::Engine;
        let mut accum = KittyAccumulator::new();
        // 1x1 blue RGBA pixel, split across 2 chunks
        let pixels: Vec<u8> = vec![0, 0, 255, 255];
        let b64 = base64::engine::general_purpose::STANDARD.encode(&pixels);
        let mid = b64.len() / 2;
        let chunk1 = &b64[..mid];
        let chunk2 = &b64[mid..];

        // First chunk: m=1 (more coming)
        let control1 = "a=T,f=32,s=1,v=1,m=1";
        match accum.feed(control1, chunk1.as_bytes()) {
            KittyAction::Continue => {} // expected
            other => panic!("Expected Continue, got {:?}", other),
        }

        // Second chunk: m=0 (final)
        let control2 = "m=0";
        match accum.feed(control2, chunk2.as_bytes()) {
            KittyAction::Display {
                rgba,
                width,
                height,
            } => {
                assert_eq!(width, 1);
                assert_eq!(height, 1);
                assert_eq!(rgba[0], 0); // R
                assert_eq!(rgba[1], 0); // G
                assert_eq!(rgba[2], 255); // B
                assert_eq!(rgba[3], 255); // A
            }
            other => panic!("Expected Display, got {:?}", other),
        }
    }

    #[test]
    fn test_kitty_delete() {
        let mut accum = KittyAccumulator::new();
        match accum.feed("a=d,i=42", b"") {
            KittyAction::Delete { id } => assert_eq!(id, 42),
            other => panic!("Expected Delete, got {:?}", other),
        }
    }

    #[test]
    fn test_kitty_parse_control() {
        let params = parse_kitty_control("a=T,f=100,i=1,s=80,v=24");
        assert_eq!(params.get("a").unwrap(), "T");
        assert_eq!(params.get("f").unwrap(), "100");
        assert_eq!(params.get("i").unwrap(), "1");
        assert_eq!(params.get("s").unwrap(), "80");
        assert_eq!(params.get("v").unwrap(), "24");
    }

    #[test]
    fn test_image_store() {
        let mut store = ImageStore::new();
        assert!(!store.has_pending());

        let img = DecodedImage {
            id: 0,
            width: 10,
            height: 10,
            rgba: vec![0u8; 400],
            anchor_row: 0,
            anchor_col: 0,
            protocol: ImageProtocol::Sixel,
        };
        let id = store.push(img);
        assert_eq!(id, 1);
        assert!(store.has_pending());

        let images = store.take_pending();
        assert_eq!(images.len(), 1);
        assert_eq!(images[0].id, 1);
        assert!(!store.has_pending());
    }
}
