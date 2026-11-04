//! One cached QR per pairing payload, encoded off the UI thread while this section is visible.
use chau7_next_core::remote::{models::RemotePairingInfo, pairing_qr::PairingQrImage};
use chrono::{DateTime, Utc};
use gpui::{Context, Render, RenderImage, Task, Window, div, img, prelude::*, px};
use std::sync::Arc;

#[derive(Default)]
pub(super) struct PairingQrView {
    info: Option<RemotePairingInfo>,
    image: Option<Arc<RenderImage>>,
    width: u32,
    error: Option<&'static str>,
    task: Option<Task<()>>,
}

impl PairingQrView {
    pub(super) fn set_info(&mut self, info: Option<RemotePairingInfo>, cx: &mut Context<Self>) {
        if self.info == info {
            return;
        }
        // Dropping the task cancels both stale completion and its one-shot expiry timer.
        self.task = None;
        self.image = None;
        self.error = None;
        self.info = info.clone();
        let Some(info) = info else {
            cx.notify();
            return;
        };
        let job = cx.background_executor().spawn(async move {
            let raster = PairingQrImage::render(&info, Utc::now())?;
            let expiry = DateTime::parse_from_rfc3339(&info.expires_at)
                .map_err(|_| "The pairing expiry is invalid. Refresh the code.")?
                .to_utc();
            let pixels = image::RgbaImage::from_raw(raster.width, raster.width, raster.pixels)
                .ok_or("Cannot render the pairing QR. Refresh the code.")?;
            Ok::<_, &'static str>((
                raster.width,
                Arc::new(RenderImage::new(vec![image::Frame::new(pixels)])),
                expiry,
            ))
        });
        self.task = Some(cx.spawn(async move |weak, cx| {
            let result = job.await;
            let expiry = weak
                .update(cx, |view, cx| {
                    let expiry = match result {
                        Ok((width, image, expiry)) if expiry > Utc::now() => {
                            view.width = width;
                            view.image = Some(image);
                            Some(expiry)
                        }
                        Ok(_) => {
                            view.error = Some("This pairing code has expired. Refresh the code.");
                            None
                        }
                        Err(error) => {
                            view.error = Some(error);
                            None
                        }
                    };
                    cx.notify();
                    expiry
                })
                .ok()
                .flatten();
            let Some(expiry) = expiry else { return };
            let delay = (expiry - Utc::now()).to_std().unwrap_or_default();
            cx.background_executor().timer(delay).await;
            let _ = weak.update(cx, |view, cx| {
                view.image = None;
                view.error = Some("This pairing code has expired. Refresh the code.");
                cx.notify();
            });
        }));
        cx.notify();
    }
}

impl Render for PairingQrView {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        let mut body = div().id("remote-pairing-qr").flex().flex_col().gap_2();
        if let Some(image) = &self.image {
            body = body
                .child(
                    img(image.clone())
                        .w(px(self.width as f32))
                        .h(px(self.width as f32))
                        .flex_shrink_0(),
                )
                .child("On your iPhone, tap Pair, then Scan QR Code. Keep this code private.");
        } else if let Some(error) = self.error {
            body = body.child(error);
        } else if self.info.is_some() {
            body = body.child("Preparing secure pairing QR…");
        }
        body
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use gpui::{AppContext, TestAppContext, WindowOptions};

    fn info(code: &str) -> RemotePairingInfo {
        RemotePairingInfo {
            device_id: "fixture-device".into(),
            mac_pub: "fixture-public-key".into(),
            pairing_code: code.into(),
            relay_url: "wss://relay.test/connect".into(),
            expires_at: (Utc::now() + chrono::Duration::seconds(60)).to_rfc3339(),
            relay_key_id: Some("fixture-key".into()),
            relay_secret: Some("AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE".into()),
        }
    }

    #[gpui::test]
    fn qr_reuses_unchanged_image_and_clears_on_hide_and_expiry(harness: &mut TestAppContext) {
        let mut fixture = harness.new_app();
        let cx = &mut fixture;
        let (_window, view) = cx.update(|cx| {
            gpui_kit::init(cx);
            gpui_kit::open_window(WindowOptions::default(), cx, |_, cx| {
                cx.new(|_| PairingQrView::default())
            })
            .unwrap()
        });
        let pairing = info("123456");
        cx.update(|cx| view.update(cx, |view, cx| view.set_info(Some(pairing.clone()), cx)));
        cx.run_until_parked();
        let image = cx.update(|cx| view.read(cx).image.clone().expect("QR generated"));
        cx.update(|cx| {
            view.update(cx, |view, cx| {
                view.set_info(Some(pairing), cx);
                assert!(Arc::ptr_eq(view.image.as_ref().unwrap(), &image));
                view.set_info(None, cx);
                assert!(view.image.is_none());
                assert!(view.task.is_none());
            })
        });
        cx.background_executor
            .advance_clock(std::time::Duration::from_secs(120));
        cx.run_until_parked();
        cx.update(|cx| {
            assert!(
                view.read(cx).error.is_none(),
                "cancelled expiry must not write stale state"
            )
        });
        cx.update(|cx| view.update(cx, |view, cx| view.set_info(Some(info("654321")), cx)));
        cx.run_until_parked();
        cx.update(|cx| assert!(view.read(cx).image.is_some()));
        cx.background_executor
            .advance_clock(std::time::Duration::from_secs(120));
        cx.run_until_parked();
        cx.update(|cx| {
            assert!(view.read(cx).image.is_none());
            assert!(view.read(cx).error.unwrap().contains("expired"));
        });
    }

    #[gpui::test]
    fn replaced_or_disabled_payload_cannot_publish_a_stale_qr(harness: &mut TestAppContext) {
        let mut fixture = harness.new_app();
        let cx = &mut fixture;
        let (_window, view) = cx.update(|cx| {
            gpui_kit::init(cx);
            gpui_kit::open_window(WindowOptions::default(), cx, |_, cx| {
                cx.new(|_| PairingQrView::default())
            })
            .unwrap()
        });
        cx.update(|cx| {
            view.update(cx, |view, cx| {
                view.set_info(Some(info("123456")), cx);
                view.set_info(None, cx);
            })
        });
        cx.run_until_parked();
        cx.update(|cx| {
            assert!(view.read(cx).info.is_none());
            assert!(view.read(cx).image.is_none());
        });
        cx.update(|cx| {
            view.update(cx, |view, cx| {
                let mut invalid = info("654321");
                invalid.relay_secret = None;
                view.set_info(Some(invalid), cx);
            })
        });
        cx.run_until_parked();
        cx.update(|cx| {
            assert!(view.read(cx).image.is_none());
            assert!(view.read(cx).error.unwrap().contains("credentials"));
        });
    }
}
