//! The picture editor's geometry and output, as Rails' banner-editor does it
//! (drag to reposition, a 1x-3x zoom toward the centre, Cancel/Apply) with
//! Flutter's improvement: the avatar circle is always covered, never showing
//! empty space. The crop is baked into the uploaded image, as in Rails, so
//! nothing extra is stored on the profile.

/// What's being edited, and its output.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Target {
    /// A 512px square, clipped to a circle (Rails).
    Avatar,
    /// 960px wide, the viewport's aspect (Rails).
    Banner,
    /// A server icon: a 512px square, shown with rounded corners.
    Icon,
}

/// Editor state, in viewport points. The image's top-left sits at `offset`
/// and each source pixel is `scale` points wide.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Crop {
    pub target: Target,
    pub src: (f64, f64),
    pub view: (f64, f64),
    /// 1.0..=3.0 on top of the fit scale.
    pub zoom: f64,
    pub offset: (f64, f64),
}

/// Rails' snapping distance (points).
const SNAP: f64 = 8.0;

impl Crop {
    pub fn new(target: Target, src: (f64, f64), view: (f64, f64)) -> Crop {
        let mut c = Crop { target, src, view, zoom: 1.0, offset: (0.0, 0.0) };
        let s = c.scale();
        c.offset = ((view.0 - src.0 * s) / 2.0, (view.1 - src.1 * s) / 2.0);
        c.clamp();
        c
    }

    /// The region that becomes the output: the avatar circle's square, or
    /// the whole banner viewport.
    pub fn region(&self) -> (f64, f64, f64, f64) {
        match self.target {
            Target::Avatar | Target::Icon => {
                let d = self.view.0.min(self.view.1) * 0.8;
                ((self.view.0 - d) / 2.0, (self.view.1 - d) / 2.0, d, d)
            }
            Target::Banner => (0.0, 0.0, self.view.0, self.view.1),
        }
    }

    /// Points per source pixel: the smallest scale that covers the region,
    /// times the zoom.
    pub fn scale(&self) -> f64 {
        let (_, _, w, h) = self.region();
        let fit = (w / self.src.0.max(1.0)).max(h / self.src.1.max(1.0));
        fit * self.zoom
    }

    /// Zooms to `zoom` (clamped to 1-3x), keeping the viewport's centre on
    /// the same spot of the image.
    pub fn set_zoom(&mut self, zoom: f64) {
        let before = self.scale();
        self.zoom = zoom.clamp(1.0, 3.0);
        let after = self.scale();
        let (cx, cy) = (self.view.0 / 2.0, self.view.1 / 2.0);
        self.offset = (cx - (cx - self.offset.0) * after / before, cy - (cy - self.offset.1) * after / before);
        self.clamp();
    }

    pub fn drag(&mut self, dx: f64, dy: f64) {
        self.offset = (self.offset.0 + dx, self.offset.1 + dy);
        self.snap();
        self.clamp();
    }

    /// The image always covers the output region: no empty edges on a banner,
    /// no gap inside the avatar circle or icon square.
    fn clamp(&mut self) {
        let s = self.scale();
        let (rx, ry, rw, rh) = self.region();
        let (w, h) = (self.src.0 * s, self.src.1 * s);
        self.offset.0 = self.offset.0.clamp(rx + rw - w, rx);
        self.offset.1 = self.offset.1.clamp(ry + rh - h, ry);
    }

    /// Rails: the banner snaps to centred and to its edges within 8 points.
    fn snap(&mut self) {
        if self.target != Target::Banner {
            return;
        }
        let s = self.scale();
        let (w, h) = (self.src.0 * s, self.src.1 * s);
        let centred = ((self.view.0 - w) / 2.0, (self.view.1 - h) / 2.0);
        for (v, targets) in [
            (&mut self.offset.0, [centred.0, 0.0, self.view.0 - w]),
            (&mut self.offset.1, [centred.1, 0.0, self.view.1 - h]),
        ] {
            if let Some(t) = targets.iter().find(|t| (*v - **t).abs() < SNAP) {
                *v = *t;
            }
        }
    }

    pub fn output_size(&self) -> (usize, usize) {
        match self.target {
            Target::Avatar | Target::Icon => (512, 512),
            Target::Banner => (960, (960.0 * self.view.1 / self.view.0).round().max(1.0) as usize),
        }
    }

    /// Renders the crop from `pixels` (0xAARRGGBB, row-major, `src` sized) to
    /// RGBA bytes at `output_size`, bilinear; the avatar is clipped to a
    /// circle with an antialiased edge.
    pub fn render(&self, pixels: &[u32]) -> Vec<u8> {
        let (ow, oh) = self.output_size();
        let (rx, ry, rw, rh) = self.region();
        let s = self.scale();
        let (sw, sh) = (self.src.0 as usize, self.src.1 as usize);
        let px = |x: i64, y: i64| -> [f64; 4] {
            let x = x.clamp(0, sw as i64 - 1) as usize;
            let y = y.clamp(0, sh as i64 - 1) as usize;
            let p = pixels[y * sw + x];
            [((p >> 16) & 255) as f64, ((p >> 8) & 255) as f64, (p & 255) as f64, (p >> 24) as f64]
        };
        let mut out = vec![0u8; ow * oh * 4];
        for oy in 0..oh {
            for ox in 0..ow {
                let vx = rx + (ox as f64 + 0.5) * rw / ow as f64;
                let vy = ry + (oy as f64 + 0.5) * rh / oh as f64;
                let sx = (vx - self.offset.0) / s - 0.5;
                let sy = (vy - self.offset.1) / s - 0.5;
                let (x0, y0) = (sx.floor(), sy.floor());
                let (fx, fy) = (sx - x0, sy - y0);
                let (x0, y0) = (x0 as i64, y0 as i64);
                let (a, b, c, d) = (px(x0, y0), px(x0 + 1, y0), px(x0, y0 + 1), px(x0 + 1, y0 + 1));
                let mut rgba = [0.0; 4];
                for k in 0..4 {
                    rgba[k] = (a[k] * (1.0 - fx) + b[k] * fx) * (1.0 - fy) + (c[k] * (1.0 - fx) + d[k] * fx) * fy;
                }
                if self.target == Target::Avatar {
                    let r = ow as f64 / 2.0;
                    let dist = ((ox as f64 + 0.5 - r).powi(2) + (oy as f64 + 0.5 - r).powi(2)).sqrt();
                    rgba[3] *= (r - dist + 0.5).clamp(0.0, 1.0);
                }
                let i = (oy * ow + ox) * 4;
                for k in 0..4 {
                    out[i + k] = rgba[k].round().clamp(0.0, 255.0) as u8;
                }
            }
        }
        out
    }

    /// The finished PNG.
    pub fn encode(&self, pixels: &[u32]) -> Result<Vec<u8>, String> {
        use makepad_zune_png::makepad_zune_core::{bit_depth::BitDepth, colorspace::ColorSpace, options::EncoderOptions};
        let (w, h) = self.output_size();
        let rgba = self.render(pixels);
        let options = EncoderOptions::default().set_width(w).set_height(h).set_depth(BitDepth::Eight).set_colorspace(ColorSpace::RGBA);
        let mut png = Vec::new();
        makepad_zune_png::PngEncoder::new(&rgba, options).encode(&mut png).map_err(|e| format!("{e:?}"))?;
        Ok(png)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn avatar_always_covers_the_circle() {
        let mut c = Crop::new(Target::Avatar, (1000.0, 500.0), (480.0, 300.0));
        let (rx, ry, rw, rh) = c.region();
        assert_eq!((rw, rh), (240.0, 240.0));
        // Fit covers the circle's square exactly in height.
        assert!((c.src.1 * c.scale() - rh).abs() < 1e-9);
        c.drag(10_000.0, 10_000.0);
        assert_eq!(c.offset, (rx, ry), "dragged as far as it goes: the image's corner at the region's");
        c.drag(-10_000.0, -10_000.0);
        let s = c.scale();
        assert!((c.offset.0 + c.src.0 * s - (rx + rw)).abs() < 1e-9);
    }

    #[test]
    fn zoom_keeps_the_centre_and_clamps() {
        let mut c = Crop::new(Target::Banner, (1920.0, 1080.0), (480.0, 200.0));
        let centre = |c: &Crop| ((240.0 - c.offset.0) / c.scale(), (100.0 - c.offset.1) / c.scale());
        let before = centre(&c);
        c.set_zoom(2.0);
        let after = centre(&c);
        assert!((before.0 - after.0).abs() < 1e-6 && (before.1 - after.1).abs() < 1e-6);
        c.set_zoom(9.0);
        assert_eq!(c.zoom, 3.0);
    }

    #[test]
    fn banner_snaps_to_centre() {
        let mut c = Crop::new(Target::Banner, (1920.0, 1080.0), (480.0, 200.0));
        c.set_zoom(2.0);
        let centred = c.offset;
        c.drag(5.0, -3.0);
        assert_eq!(c.offset, centred);
        assert_eq!(c.output_size(), (960, 400));
    }

    #[test]
    fn icons_are_square_and_unclipped() {
        let c = Crop::new(Target::Icon, (2.0, 2.0), (300.0, 300.0));
        assert_eq!(c.output_size(), (512, 512));
        assert_eq!(c.render(&[0xff00ff00; 4])[3], 255, "the corner stays: rounding is the viewer's");
    }

    #[test]
    fn renders_a_clipped_avatar() {
        // 2x2 red image, scaled up: a red disc with transparent corners.
        let red = 0xffff0000u32;
        let c = Crop::new(Target::Avatar, (2.0, 2.0), (300.0, 300.0));
        let rgba = c.render(&[red; 4]);
        let at = |x: usize, y: usize| &rgba[(y * 512 + x) * 4..(y * 512 + x) * 4 + 4];
        assert_eq!(at(256, 256), &[255, 0, 0, 255]);
        assert_eq!(at(0, 0)[3], 0, "corner outside the circle");
        let png = c.encode(&[red; 4]).unwrap();
        assert_eq!(&png[1..4], b"PNG");
    }
}
