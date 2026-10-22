// The overlay's two looks, as the WPF overlay has them
// ($script:ChatOverlayPalettes, src/overlay-windows.ps1): each colour by its
// name, the two washes a tile takes of its state's colour and the tray dot's
// ring. The dark look's serif is the console's alone, which stays WPF's
// (Set-ChatOverlaySerif): no title here is drawn in it. A name gives its
// colour as Get-ChatOverlayBrush does: a name in the palette (any case, as a
// PowerShell hashtable reads it), or #RRGGBB / #AARRGGBB itself, and any
// other name the text colour.

pub struct Look {
    pub name: &'static str,
    colors: &'static [(&'static str, u32)],
    /// how much of its state's colour a tile takes for a chat that needs
    /// you, and for one at work (Get-ChatOverlayTileWash)
    pub wash_need: f64,
    pub wash_work: f64,
    /// the tray dot's ring, #RRGGBB (Set-ChatOverlayTrayColor)
    pub tray_ring: u32,
}

const DARK: Look = Look {
    name: "dark",
    colors: &[
        ("waiting", 0xFFF5B942),
        ("needs-input", 0xFFF5B942),
        ("busy", 0xFF4CC38A),
        ("running", 0xFF4EA1FF),
        ("idle", 0xFF80868F),
        ("queued", 0xFFB48CFF),
        ("cutoff", 0xFFFF8A4C),
        ("recent", 0xFFA08E8F),
        ("text", 0xFFF2E8DC),
        ("dim", 0xFFC2B1AE),
        ("faint", 0xFFA08E8F),
        ("project", 0xFFF2B3C6),
        ("frame", 0xF21A0B12),
        ("edge", 0x55B09A6C),
        ("unlocked", 0xFFFF4FB4),
        ("track", 0x2EFFE6DC),
        ("normal", 0xFFD8C8BE),
        ("warning", 0xFFF5B942),
        ("critical", 0xFFFF5C5C),
        ("warn", 0xFFF5B942),
        ("error", 0xFFFF7B72),
        ("panel", 0xF7271219),
        ("hover", 0x55B0203C),
        ("accent", 0xFFFF4FB4),
        ("onAccent", 0xFF1A0B12),
        ("window", 0xFF1F0F17),
        ("input", 0xFF150A10),
        ("inputEdge", 0x70B09A6C),
        ("select", 0x1FFF4FB4),
        ("ghost", 0x17FFE6D8),
        ("trim", 0xFFB09A6C),
    ],
    wash_need: 0.22,
    wash_work: 0.10,
    tray_ring: 0x6E0F24,
};

const LIGHT: Look = Look {
    name: "light",
    colors: &[
        ("waiting", 0xFFC98A00),
        ("needs-input", 0xFFC98A00),
        ("busy", 0xFF1A8F4C),
        ("running", 0xFF1F6FEB),
        ("idle", 0xFF8C959F),
        ("queued", 0xFF8250DF),
        ("cutoff", 0xFFBC4C00),
        ("recent", 0xFF8C959F),
        ("text", 0xFF1F2328),
        ("dim", 0xFF57606A),
        ("faint", 0xFF8C959F),
        ("project", 0xFF0969DA),
        ("frame", 0xF2FAFAFB),
        ("edge", 0x26000000),
        ("unlocked", 0xFF0969DA),
        ("track", 0x1F000000),
        ("normal", 0xFF0969DA),
        ("warning", 0xFFBF8700),
        ("critical", 0xFFCF222E),
        ("warn", 0xFF9A6700),
        ("error", 0xFFCF222E),
        ("panel", 0xFAFFFFFF),
        ("hover", 0x1A000000),
        ("accent", 0xFF0969DA),
        ("onAccent", 0xFFFFFFFF),
        ("window", 0xFFF6F8FA),
        ("input", 0xFFFFFFFF),
        ("inputEdge", 0x40000000),
        ("select", 0x290969DA),
        ("ghost", 0x0E000000),
        ("trim", 0x26000000),
    ],
    wash_need: 0.15,
    wash_work: 0.08,
    tray_ring: 0x130A1E,
};

/// The look a theme names: light, or dark for anything else - the panel
/// resolves 'system' before it asks (app.rs, through win32::system_dark;
/// Resolve-ChatOverlayTheme).
pub fn look(theme: &str) -> &'static Look {
    if theme.eq_ignore_ascii_case("light") {
        &LIGHT
    } else {
        &DARK
    }
}

/// #RRGGBB or #AARRGGBB as 0xAARRGGBB; None for anything else.
fn hex(s: &str) -> Option<u32> {
    let h = s.strip_prefix('#')?;
    let v = u32::from_str_radix(h, 16).ok()?;
    match h.len() {
        6 => Some(0xFF00_0000 | v),
        8 => Some(v),
        _ => None,
    }
}

impl Look {
    /// The colour a name gives, as 0xAARRGGBB.
    pub fn argb(&self, name: &str) -> u32 {
        if name.starts_with('#')
            && let Some(v) = hex(name)
        {
            return v;
        }
        self.colors
            .iter()
            .find(|(n, _)| n.eq_ignore_ascii_case(name))
            .or_else(|| self.colors.iter().find(|(n, _)| *n == "text"))
            .map_or(0xFF00_0000, |&(_, v)| v)
    }

    /// A tile's ground: its state's colour at the wash for a chat that
    /// needs you or one at work, none for the rest
    /// (Get-ChatOverlayTileWash): alpha [Math]::Round(255 * wash), which
    /// rounds half to even.
    pub fn tile_wash(&self, status: &str) -> u32 {
        let a = match status.to_ascii_lowercase().as_str() {
            "waiting" | "needs-input" | "cutoff" => self.wash_need,
            "busy" | "running" => self.wash_work,
            _ => 0.0,
        };
        self.washed(status, a)
    }

    /// A notice box's ground: its tone washed in as a chat that needs you,
    /// none for dim and faint (Add-ChatOverlayNotice). A tone the palette
    /// does not name, a #hex among them, gets none either: the ground there
    /// is cut from the palette's own entry for the tone.
    pub fn notice_wash(&self, tone: &str) -> u32 {
        let named = self
            .colors
            .iter()
            .any(|(n, _)| n.eq_ignore_ascii_case(tone));
        if !named || tone.eq_ignore_ascii_case("dim") || tone.eq_ignore_ascii_case("faint") {
            return 0;
        }
        self.washed(tone, self.wash_need)
    }

    fn washed(&self, name: &str, a: f64) -> u32 {
        let alpha = (255.0 * a).round_ties_even() as u32;
        (alpha << 24) | (self.argb(name) & 0x00FF_FFFF)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_hex_and_the_text_fallback() {
        let d = look("dark");
        assert_eq!(d.argb("waiting"), 0xFFF5B942);
        assert_eq!(d.argb("Waiting"), 0xFFF5B942, "a hashtable reads any case");
        assert_eq!(d.argb("frame"), 0xF21A0B12);
        assert_eq!(d.argb("#01000000"), 0x01000000);
        assert_eq!(d.argb("#123456"), 0xFF123456);
        assert_eq!(d.argb("no-such"), d.argb("text"));
        assert_eq!(look("LIGHT").name, "light");
        assert_eq!(look("system").name, "dark");
    }

    /// 255 * 0.10 is 25.5 to the double, which [Math]::Round takes to 26.
    #[test]
    fn washes_round_half_to_even() {
        let d = look("dark");
        assert_eq!(d.tile_wash("busy") >> 24, 26);
        assert_eq!(d.tile_wash("waiting") >> 24, 56);
        assert_eq!(d.tile_wash("idle") >> 24, 0);
        let l = look("light");
        assert_eq!(l.tile_wash("cutoff"), (38 << 24) | 0xBC4C00);
        assert_eq!(l.tile_wash("running") >> 24, 20);
        assert_eq!(d.notice_wash("dim") >> 24, 0);
        assert_eq!(d.notice_wash("error"), (56 << 24) | 0xFF7B72);
        assert_eq!(d.notice_wash("#FF0000"), 0);
        assert_eq!(d.notice_wash("no-such"), 0);
    }
}
