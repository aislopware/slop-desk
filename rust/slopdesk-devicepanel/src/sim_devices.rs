//! The host's simulator set as the panel sees it, decoded from `/simulators.json`.
//!
//! The server answers two arrays, `running` and `available`, of identical objects. This folds them
//! into ONE list carrying the boot state, because that is what the panel renders: a device does not
//! change identity when it boots, and a list that reorders itself under the cursor on every poll is
//! the exact opposite of what a person clicking "Boot" wants to see. Order is therefore the
//! server's own within each group, running first — stable across polls because the server's is.
//!
//! [`Device::state`] keeps the server's raw string alongside the derived [`Device::is_booted`]. The
//! strings observed are `Booted` and `Shutdown`, but `simctl` has more — `Booting`, `Shutting
//! Down`, `Creating` — and a closed enum here would turn a transient state into a decode failure
//! for the whole list.
//!
//! ## What is refused, and what is dropped
//!
//! `None` comes back for exactly one thing: a top level that is not an object. A malformed DEVICE
//! inside is SKIPPED, so one bad entry cannot blank the panel. That is this crate's standing rule
//! for a foreign wire — validate then drop — applied at the row rather than at the envelope.

use serde_json::{Map, Value};

/// One simulator, as the sidebar lists it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Device {
    /// The identity. The only field with no sane default: a row that cannot be acted on is worse
    /// than an absent one.
    pub udid: String,
    /// The label, falling back to the udid so a server that renames a field still lists the device.
    pub name: String,
    /// The runtime, or the empty string.
    pub runtime: String,
    /// The server's own state string, verbatim.
    pub state: String,
    /// Whether [`Device::state`] names the booted state, compared without regard to case.
    pub is_booted: bool,
}

/// Decode the `/simulators.json` envelope, running group first.
///
/// `None` only for a top level that is not an object — see the module header.
#[must_use]
pub fn decode_list(bytes: &[u8]) -> Option<Vec<Device>> {
    let root: Value = serde_json::from_slice(bytes).ok()?;
    let root = root.as_object()?;
    // Running first: the device someone is working with belongs at the top, and the group a device
    // sits in is the one thing about the list that legitimately changes under a poll.
    let mut devices = decode_group(root.get("running"));
    devices.extend(decode_group(root.get("available")));
    Some(devices)
}

/// One group. A value that is not an array of objects is NO devices rather than the objects among
/// them: the Swift `as? [[String: Any]]` this replaces was all-or-nothing over the elements, and a
/// server that has changed the element shape is not one to guess with.
fn decode_group(value: Option<&Value>) -> Vec<Device> {
    let Some(entries) = value.and_then(Value::as_array) else {
        return Vec::new();
    };
    if !entries.iter().all(Value::is_object) {
        return Vec::new();
    }
    entries.iter().filter_map(decode_device).collect()
}

/// One device, or `None` for a row with no identity to act on.
fn decode_device(entry: &Value) -> Option<Device> {
    let entry = entry.as_object()?;
    let udid = entry.get("udid")?.as_str()?;
    if udid.is_empty() {
        return None;
    }
    let state = text(entry, "state", "");
    Some(Device {
        udid: udid.to_owned(),
        name: text(entry, "name", udid),
        runtime: text(entry, "runtime", ""),
        // Case-insensitive: the comparison exists to drive an affordance (Boot vs Shutdown), and
        // getting it wrong because of a capitalisation change offers the user the button that does
        // nothing. ASCII folding is the whole of it — the token is the server's own literal and has
        // no case-folding subtleties in it.
        is_booted: state.eq_ignore_ascii_case("Booted"),
        state,
    })
}

/// One string field, or `fallback` when it is absent or is not a string.
fn text(entry: &Map<String, Value>, key: &str, fallback: &str) -> String {
    entry
        .get(key)
        .and_then(Value::as_str)
        .unwrap_or(fallback)
        .to_owned()
}

#[cfg(test)]
mod tests {
    use super::decode_list;

    /// The envelope MEASURED off a live `baguette serve`.
    const ENVELOPE: &[u8] = br#"
        {"running":[{"name":"iPhone 17 Pro","runtime":"iOS 26.5","state":"Booted",
        "udid":"01D1D359-3FC8-424F-B1B1-48A767B46273"}],
        "available":[{"name":"iPhone Air","runtime":"iOS 26.5","state":"Shutdown",
        "udid":"2B0FD506-4988-438A-A877-EAE5385AD6B8"}]}
    "#;

    fn names(json: &[u8]) -> Option<Vec<String>> {
        decode_list(json).map(|devices| devices.into_iter().map(|device| device.name).collect())
    }

    /// The two arrays fold into ONE list with running first.
    #[test]
    fn the_two_arrays_fold_into_one_list_with_running_first() {
        assert_eq!(
            names(ENVELOPE),
            Some(vec!["iPhone 17 Pro".to_owned(), "iPhone Air".to_owned()])
        );
        let booted = decode_list(ENVELOPE)
            .map(|devices| devices.iter().map(|device| device.is_booted).collect::<Vec<_>>());
        assert_eq!(booted, Some(vec![true, false]));
        let first = decode_list(ENVELOPE).and_then(|devices| devices.into_iter().next());
        assert_eq!(
            first.map(|device| (device.runtime, device.udid)),
            Some((
                "iOS 26.5".to_owned(),
                "01D1D359-3FC8-424F-B1B1-48A767B46273".to_owned()
            ))
        );
    }

    /// The booted flag is case-insensitive: it drives which affordance the row offers, and getting
    /// it wrong shows the button that does nothing.
    #[test]
    fn the_booted_flag_is_case_insensitive() {
        let booted = decode_list(br#"{"running":[{"udid":"u","state":"BOOTED"}]}"#)
            .and_then(|devices| devices.into_iter().next())
            .map(|device| device.is_booted);
        assert_eq!(booted, Some(true));
    }

    /// A transient state is CARRIED rather than rejected. A closed enum here would turn a state the
    /// device passes through into a decode failure for the whole list.
    #[test]
    fn a_transient_state_is_carried_rather_than_rejected() {
        let device = decode_list(br#"{"running":[{"udid":"u","state":"Booting"}]}"#)
            .and_then(|devices| devices.into_iter().next());
        assert_eq!(
            device.map(|device| (device.state, device.is_booted)),
            Some(("Booting".to_owned(), false))
        );
    }

    /// One malformed device cannot blank the list — the panel stays useful when the server grows a
    /// field or ships one bad row.
    #[test]
    fn one_malformed_device_cannot_blank_the_list() {
        let udids = decode_list(br#"{"available":[{"state":"Shutdown"},{"udid":"good","name":"Real"}]}"#)
            .map(|devices| devices.into_iter().map(|device| device.udid).collect::<Vec<_>>());
        assert_eq!(udids, Some(vec!["good".to_owned()]));
        // A blank identity is no identity: it is the key every verb is addressed by.
        let udids = decode_list(br#"{"available":[{"udid":""},{"udid":"good"}]}"#)
            .map(|devices| devices.into_iter().map(|device| device.udid).collect::<Vec<_>>());
        assert_eq!(udids, Some(vec!["good".to_owned()]));
    }

    /// A device missing its name falls back to its identity; dropping it would hide a real device.
    #[test]
    fn a_device_missing_its_name_falls_back_to_its_identity() {
        let device =
            decode_list(br#"{"available":[{"udid":"abc"}]}"#).and_then(|devices| devices.into_iter().next());
        assert_eq!(
            device.map(|device| (device.name, device.runtime, device.state)),
            Some(("abc".to_owned(), String::new(), String::new()))
        );
    }

    /// Only a non-object top level is refused. An object with neither array is an empty device set,
    /// not a failure.
    #[test]
    fn only_a_non_object_top_level_is_refused() {
        assert_eq!(decode_list(b"[]"), None);
        assert_eq!(decode_list(b"not json"), None);
        assert_eq!(decode_list(b""), None);
        assert_eq!(decode_list(&[0xFF, 0xFE]), None);
        assert_eq!(decode_list(b"{}").map(|devices| devices.len()), Some(0));
    }

    /// A group that is not an array of objects reads as no devices rather than as the objects
    /// among them.
    #[test]
    fn a_group_that_is_not_an_array_of_objects_reads_as_none() {
        assert_eq!(
            decode_list(br#"{"running":7,"available":[{"udid":"a"}]}"#).map(|devices| devices.len()),
            Some(1)
        );
        assert_eq!(
            decode_list(br#"{"running":[9,{"udid":"a"}]}"#).map(|devices| devices.len()),
            Some(0)
        );
    }
}
