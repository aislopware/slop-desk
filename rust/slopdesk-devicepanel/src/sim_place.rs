//! Simulated GPS: the coordinate parse, its rounding, and the shortlist of places worth one tap.
//!
//! Separate from the transport for the usual reason: what the server does with a coordinate is
//! plumbing, but "is this string a coordinate" is the part that is wrong SILENTLY. A refused
//! coordinate is a disabled button and nobody is confused. A coordinate parsed wrong pins the
//! device somewhere plausible, the panel reports success, and the only evidence is an app that
//! thinks it is in the wrong hemisphere. Hence the range checks, and the refusal to guess at a
//! separator this module does not recognise.
//!
//! The server also accepts a `{waypoints:[…]}` route and a bearing/speed walk. Neither is offered:
//! both are motion over time, they want a map to draw the path on, and a sidebar column is not
//! where anyone plots a route. A single pinned position is the case a coding tool actually has —
//! "run the app as if it were in Tokyo" — and it is the whole of what this models.
//!
//! ## One deliberate difference from the Swift it replaces
//!
//! Rust's float parse refuses a C99 hex-float literal (`0x1p3`) where Swift's `Double(_: String)`
//! accepts it. Nothing pins that gap, and refusing is what this module's own stated intent asks
//! for — a hex float is not a thing a map app puts on the clipboard.

/// A pinned position. Degrees, in the server's own field names.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Coordinate {
    /// Degrees north, `-90` to `90`.
    pub latitude: f64,
    /// Degrees east, `-180` to `180`.
    pub longitude: f64,
}

impl Coordinate {
    /// Builds a coordinate without checking it. [`Coordinate::parse`] is the checked way in; this
    /// exists for the shortlist below, whose numbers are in the source.
    #[must_use]
    pub const fn new(latitude: f64, longitude: f64) -> Self {
        Self { latitude, longitude }
    }

    /// `37.334886, -122.008988` — the format every map app copies to the clipboard, which is where
    /// a coordinate typed into this field almost always comes from. A bare space separator works
    /// too; anything else is refused rather than guessed at.
    #[must_use]
    pub fn parse(text: &str) -> Option<Self> {
        let mut parts = text
            .split([',', ' '])
            .map(|part| part.trim_matches(is_horizontal_space))
            .filter(|part| !part.is_empty());
        let latitude = parts.next()?;
        let longitude = parts.next()?;
        // Exactly two. A third number means this is not the format, and reading the first two of a
        // degrees-minutes-seconds paste would pin the device a hundred kilometres away.
        if parts.next().is_some() {
            return None;
        }
        let latitude: f64 = latitude.parse().ok()?;
        let longitude: f64 = longitude.parse().ok()?;
        // Written as a range test so a NaN — which is outside every range — is refused. Clamping
        // instead would pin the device to a pole or a date line and call it the user's coordinate.
        if !(-90.0..=90.0).contains(&latitude) || !(-180.0..=180.0).contains(&longitude) {
            return None;
        }
        Some(Self { latitude, longitude })
    }

    /// What the panel echoes back after a successful send.
    ///
    /// Six decimals ALWAYS, padded rather than trimmed: a header figure that changes width as the
    /// value changes makes the whole facts line jump.
    #[must_use]
    pub fn readout(&self) -> String {
        format!("{:.6}, {:.6}", rounded(self.latitude), rounded(self.longitude))
    }
}

/// What the POST body carries, per field.
///
/// Six decimals is roughly a tenth of a metre — past that the digits describe nothing a simulator
/// can act on, and they make the readout unreadable. Half-away-from-zero, which is what Swift's
/// `Double.rounded()` did.
#[must_use]
pub fn rounded(degrees: f64) -> f64 {
    (degrees * 1_000_000.0).round() / 1_000_000.0
}

/// The characters a split on `,` and ` ` can still leave clinging to a part.
///
/// This is Foundation's `CharacterSet.whitespaces` — horizontal space, tab included, newline NOT.
/// A tab-separated paste is not this format and must still be refused, which is exactly what
/// leaving `\n` and `\r` out of this set does.
const fn is_horizontal_space(character: char) -> bool {
    matches!(
        character,
        ' ' | '\t' | '\u{00a0}' | '\u{1680}' | '\u{2000}'..='\u{200a}' | '\u{202f}' | '\u{205f}' | '\u{3000}'
    )
}

/// A named position, one tap away.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Place {
    /// What the row says, and the row's identity.
    pub name: &'static str,
    /// Where it is.
    pub coordinate: Coordinate,
}

/// The shortlist.
///
/// Deliberately short: a picker of two hundred cities is a search problem, and the point of the
/// list is to cover the handful of cases — a home region, the two hemispheres, a date line — that
/// catch a location bug without anyone having to look a number up. It is a bug-catching set, not a
/// gazetteer.
pub const ALL: [Place; 9] = [
    place("Apple Park", 37.334_886, -122.008_988),
    place("San Francisco", 37.774_929, -122.419_418),
    place("New York", 40.712_776, -74.005_974),
    place("London", 51.507_351, -0.127_758),
    place("Berlin", 52.520_008, 13.404_954),
    place("Ho Chi Minh City", 10.762_622, 106.660_172),
    place("Singapore", 1.352_083, 103.819_839),
    place("Tokyo", 35.689_487, 139.691_711),
    place("Sydney", -33.868_820, 151.209_290),
];

/// One row of [`ALL`].
const fn place(name: &'static str, latitude: f64, longitude: f64) -> Place {
    Place {
        name,
        coordinate: Coordinate::new(latitude, longitude),
    }
}

#[cfg(test)]
mod tests {
    use super::{ALL, Coordinate, rounded};

    /// The comma form every map app copies is accepted — this is the paste the field exists for —
    /// and so is a bare space, and so is a paste that arrived with its own padding.
    #[test]
    fn the_comma_form_every_map_app_copies_is_accepted() {
        let apple = Some(Coordinate::new(37.334_886, -122.008_988));
        assert_eq!(Coordinate::parse("37.334886, -122.008988"), apple);
        assert_eq!(Coordinate::parse("37.334886,-122.008988"), apple);
        assert_eq!(
            Coordinate::parse("  51.507351   -0.127758  "),
            Some(Coordinate::new(51.507_351, -0.127_758))
        );
        // A tab is trimmed off a part the split already made, but is not itself a separator.
        assert_eq!(
            Coordinate::parse("51.507351,\t-0.127758"),
            Some(Coordinate::new(51.507_351, -0.127_758))
        );
        assert_eq!(Coordinate::parse("51.507351\t-0.127758"), None);
    }

    /// Whole degrees and the origin parse. Zero is a real position, and a guard written as a
    /// truthiness check would reject it.
    #[test]
    fn whole_degrees_and_the_origin_parse() {
        assert_eq!(Coordinate::parse("0, 0"), Some(Coordinate::new(0.0, 0.0)));
        assert_eq!(Coordinate::parse("35, 139"), Some(Coordinate::new(35.0, 139.0)));
    }

    /// An out-of-range value is REFUSED rather than clamped, and the edges themselves are legal.
    #[test]
    fn an_out_of_range_value_is_refused_rather_than_clamped() {
        assert_eq!(Coordinate::parse("91, 0"), None);
        assert_eq!(Coordinate::parse("-91, 0"), None);
        assert_eq!(Coordinate::parse("0, 181"), None);
        assert_eq!(Coordinate::parse("0, -181"), None);
        assert_eq!(Coordinate::parse("90, 180"), Some(Coordinate::new(90.0, 180.0)));
        assert_eq!(
            Coordinate::parse("-90, -180"),
            Some(Coordinate::new(-90.0, -180.0))
        );
    }

    /// Anything that is not exactly two numbers is refused.
    #[test]
    fn anything_that_is_not_exactly_two_numbers_is_refused() {
        assert_eq!(Coordinate::parse(""), None);
        assert_eq!(Coordinate::parse("   "), None);
        assert_eq!(Coordinate::parse(","), None);
        assert_eq!(Coordinate::parse("37.334886"), None);
        assert_eq!(Coordinate::parse("37.334886, -122.008988, 12"), None);
        assert_eq!(Coordinate::parse("Apple Park"), None);
        // A degrees-minutes-seconds paste is a real thing to paste and is NOT this format.
        assert_eq!(Coordinate::parse("37°20'05.6\"N 122°00'32.4\"W"), None);
    }

    /// The float spellings that would pin the device nowhere are refused by the range check rather
    /// than parsed into a plausible-looking position.
    #[test]
    fn a_non_finite_spelling_is_refused_by_the_range_check() {
        assert_eq!(Coordinate::parse("inf, 0"), None);
        assert_eq!(Coordinate::parse("NaN, 0"), None);
        assert_eq!(Coordinate::parse("0, -infinity"), None);
    }

    /// The wire body stops at six decimals — past that the digits describe nothing a simulator can
    /// act on.
    #[test]
    fn the_body_stops_at_six_decimals() {
        assert!((rounded(37.334_886_123_4) - 37.334_886).abs() < f64::EPSILON);
        assert!((rounded(-122.008_988_123_4) + 122.008_988).abs() < f64::EPSILON);
        assert!((rounded(0.0) - 0.0).abs() < f64::EPSILON);
    }

    /// The readout is FIXED WIDTH so the header does not reflow on every pin.
    #[test]
    fn the_readout_is_fixed_width() {
        assert_eq!(Coordinate::new(0.0, 0.0).readout(), "0.000000, 0.000000");
        assert_eq!(
            Coordinate::new(37.334_886, -122.008_988).readout(),
            "37.334886, -122.008988"
        );
        assert_eq!(
            Coordinate::new(37.334_886_123_4, -122.008_988_123_4).readout(),
            "37.334886, -122.008988"
        );
    }

    /// A readout parses back into the same position. The round trip matters because the readout is
    /// what the header's Copy hands over, and the obvious next thing anyone does with it is paste
    /// it into this same field.
    #[test]
    fn a_readout_parses_back_into_the_same_position() {
        let original = Coordinate::new(-33.868_820, 151.209_290);
        assert_eq!(Coordinate::parse(&original.readout()), Some(original));
    }

    /// The presets are distinct, span the cases the list exists for, and every one of them is a
    /// position the server would accept.
    #[test]
    fn the_presets_are_distinct_and_span_the_cases_the_list_exists_for() {
        let mut names: Vec<&str> = ALL.iter().map(|place| place.name).collect();
        names.sort_unstable();
        let total = names.len();
        names.dedup();
        assert_eq!(names.len(), total);
        assert!(ALL.iter().any(|place| place.coordinate.latitude < 0.0));
        assert!(ALL.iter().any(|place| place.coordinate.longitude < 0.0));
        assert!(ALL.iter().any(|place| place.coordinate.longitude > 0.0));
        for place in ALL {
            assert_eq!(
                Coordinate::parse(&place.coordinate.readout()),
                Some(place.coordinate),
                "{} must round-trip",
                place.name
            );
        }
    }
}
