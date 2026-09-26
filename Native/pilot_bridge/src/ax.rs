use std::collections::{HashMap, HashSet};
use std::fmt::Write as _;
use std::time::Duration;

use idevice::dvt::message::{AuxValue, Message};
use idevice::dvt::remote_server::RemoteServerClient;
use idevice::rsd::RsdHandshake;
use idevice::tcp::handle::AdapterHandle;
use idevice::{Idevice, ReadWrite};
use plist::{Dictionary, Value};
use serde::Serialize;

const SERVICE_NAME: &str = "com.apple.accessibility.axAuditDaemon.remoteserver.shim.remote";
const MAX_DEPTH: usize = 12;
const MAX_NODES: usize = 300;

/// Turns off the Accessibility Inspector overlay that the focus walk otherwise paints
/// as a green box into every screenshot. Sent fire-and-forget (`expects_reply=false`):
/// a daemon that lacks a selector does not error; a socket write failure fails connect,
/// and would fail the snapshot anyway.
const INSPECTOR_HIGHLIGHT_OFF: [&str; 2] =
    ["deviceInspectorShowVisuals:", "deviceEnableHighlight:"];

pub(crate) struct AxClient {
    dtx: RemoteServerClient<Box<dyn ReadWrite>>,
    /// Latest `hostAppStateChanged:` per pid. Frontmost is the newest Foreground entry.
    app_states: HashMap<i64, AppState>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct AppState {
    display_id: String,
    pid: i64,
    state: i64,
    description: String,
    time: i64,
    exec_name: String,
    app_name: String,
}

#[derive(Debug, PartialEq, Eq, Serialize)]
struct FrontmostApp {
    name: String,
    bundle_id: String,
}

#[derive(Debug, Serialize)]
struct Element {
    id: String,
    token_hex: String,
    role: Option<String>,
    label: Option<String>,
    value: Option<String>,
    traits: Vec<String>,
    children: Vec<String>,
    ignored: bool,
}

#[derive(Default)]
struct SnapshotBuilder {
    elements: Vec<Element>,
    indexes_by_token: HashMap<String, usize>,
    used_ids: HashSet<String>,
}

impl SnapshotBuilder {
    fn merge_tree(&mut self, node: &Value, depth: usize) -> Option<String> {
        if depth > MAX_DEPTH {
            return None;
        }
        let token = node_token_hex(node)?;
        let existing = self.indexes_by_token.get(&token).copied();
        if existing.is_none() && self.elements.len() >= MAX_NODES {
            return None;
        }

        let preferred_id = direct_field(node, "AuditElementValue_v1")
            .and_then(|element| direct_string_field(element, "AccessibilityIdentifier_v1"))
            .filter(|value| !value.is_empty());
        let role = direct_string_field(node, "HumanReadableRoleDescriptionValue_v1")
            .filter(|value| !value.is_empty());
        let label = direct_string_field(node, "HumanReadableDescriptionValue_v1")
            .filter(|value| !value.is_empty());
        let ignored = direct_bool_field(node, "IsIgnoredValue_v1").unwrap_or(false);
        let index = match existing {
            Some(index) => {
                let element = &mut self.elements[index];
                if element.role.is_none() {
                    element.role = role.clone();
                }
                if element.label.is_none() {
                    element.label = label;
                }
                element.ignored = ignored;
                index
            }
            None => {
                let id = preferred_id
                    .filter(|candidate| !self.used_ids.contains(candidate))
                    .unwrap_or_else(|| token.clone());
                self.used_ids.insert(id.clone());
                let index = self.elements.len();
                self.indexes_by_token.insert(token.clone(), index);
                self.elements.push(Element {
                    id,
                    token_hex: token,
                    role: role.clone(),
                    label,
                    value: None,
                    traits: role.into_iter().collect(),
                    children: Vec::new(),
                    ignored,
                });
                index
            }
        };
        let id = self.elements[index].id.clone();

        let child_values = direct_field(node, "ChildrenValue_v1")
            .and_then(scalar)
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        let child_ids = child_values
            .iter()
            .filter_map(|child| self.merge_tree(child, depth + 1))
            .collect();
        self.elements[index].children = child_ids;
        Some(id)
    }

    fn merge_focus(&mut self, payload: &Value) {
        let Some(token) = token_hex(payload) else {
            return;
        };
        let index = match self.indexes_by_token.get(&token).copied() {
            Some(index) => index,
            None if self.elements.len() < MAX_NODES => {
                let index = self.elements.len();
                self.indexes_by_token.insert(token.clone(), index);
                self.used_ids.insert(token.clone());
                self.elements.push(Element {
                    id: token.clone(),
                    token_hex: token,
                    role: None,
                    label: None,
                    value: None,
                    traits: Vec::new(),
                    children: Vec::new(),
                    ignored: false,
                });
                index
            }
            None => return,
        };
        if let Some(label) =
            string_field(payload, "CaptionTextValue_v1").filter(|value| !value.is_empty())
        {
            self.elements[index].label = Some(label);
        }
        if let Some(value) =
            string_field(payload, "SpokenDescriptionValue_v1").filter(|value| !value.is_empty())
        {
            self.elements[index].value = Some(value);
        }
    }
}

impl AxClient {
    pub(crate) async fn connect(
        adapter: &mut AdapterHandle,
        handshake: &RsdHandshake,
    ) -> Result<Self, String> {
        let port = handshake
            .services
            .get(SERVICE_NAME)
            .ok_or_else(|| format!("RSD service {SERVICE_NAME} is unavailable"))?
            .port;
        let stream = adapter
            .connect(port)
            .await
            .map_err(|error| format!("AX service connection failed: {error:?}"))?;
        let mut service = Idevice::new(Box::new(stream), "PocketPilot AX");
        service
            .rsd_checkin()
            .await
            .map_err(|error| format!("AX RSD check-in failed: {error:?}"))?;
        let socket = service
            .get_socket()
            .ok_or_else(|| "AX service returned no socket".to_string())?;
        let mut dtx = RemoteServerClient::new(socket);
        perform_dtx_handshake(&mut dtx).await?;
        flush_initial_messages(&mut dtx).await;
        let mut client = Self {
            dtx,
            app_states: HashMap::new(),
        };
        client.disable_inspector_highlight().await?;
        Ok(client)
    }

    pub(crate) async fn snapshot(&mut self) -> Result<Vec<u8>, String> {
        self.invoke(
            "deviceSetAppMonitoringEnabled:",
            vec![AuxValue::archived_value(true)],
        )
        .await?;
        self.invoke(
            "deviceInspectorSetMonitoredEventType:",
            vec![AuxValue::archived_value(0_i64)],
        )
        .await?;
        // Monitoring (re)enables the Inspector overlay; turn it off again before
        // the walk, after each move, and after the walk so the next screenshot
        // does not capture the leftover highlight.
        self.disable_inspector_highlight().await?;
        self.advance_focus().await?;

        let mut builder = SnapshotBuilder::default();
        let mut visited_focus_tokens = HashSet::new();
        let mut consecutive_timeouts = 0;

        while builder.elements.len() < MAX_NODES {
            let message = match tokio::time::timeout(
                Duration::from_secs(1),
                self.dtx.read_message(0),
            )
            .await
            {
                Ok(Ok(message)) => {
                    consecutive_timeouts = 0;
                    message
                }
                Ok(Err(error)) => return Err(format!("AX event read failed: {error:?}")),
                Err(_) => {
                    consecutive_timeouts += 1;
                    if consecutive_timeouts >= 5 {
                        return Err("timed out waiting for accessibility focus events".into());
                    }
                    self.advance_focus().await?;
                    continue;
                }
            };

            if message.data.as_ref().and_then(Value::as_string)
                != Some("hostInspectorCurrentElementChanged:")
            {
                self.note_host_event(&message);
                continue;
            }
            let Some(payload) = decode_first_argument(&message)? else {
                continue;
            };
            let Some(focus_token) = token_hex(&payload) else {
                continue;
            };
            if !visited_focus_tokens.insert(focus_token) {
                break;
            }

            let element = find_field(&payload, "ElementValue_v1").cloned();
            let hierarchy =
                find_attribute_descriptor(&payload, "_AXHierarchyElementsAttribute").cloned();
            if let (Some(element), Some(hierarchy)) = (element, hierarchy)
                && let Ok(tree) = self.fetch_attribute(element, hierarchy).await
            {
                builder.merge_tree(&tree, 0);
            }
            builder.merge_focus(&payload);
            self.advance_focus().await?;
        }
        self.disable_inspector_highlight().await?;

        serde_json::to_vec(&builder.elements)
            .map_err(|error| format!("AX JSON serialization failed: {error}"))
    }

    pub(crate) async fn frontmost_app(&mut self) -> Result<Vec<u8>, String> {
        let started = std::time::Instant::now();
        let result = self.frontmost_app_inner().await;
        eprintln!(
            "pilot_bridge: frontmost_app {} in {}ms",
            if result.is_ok() { "ok" } else { "err" },
            started.elapsed().as_millis()
        );
        result
    }

    async fn frontmost_app_inner(&mut self) -> Result<Vec<u8>, String> {
        self.invoke(
            "deviceSetAppMonitoringEnabled:",
            vec![AuxValue::archived_value(true)],
        )
        .await?;
        self.drain_pending_host_events().await?;
        let app = self.current_frontmost().ok_or_else(|| {
            "no hostAppStateChanged: yet (Home presses will fill the map)".to_string()
        })?;
        serde_json::to_vec(&app)
            .map_err(|error| format!("frontmost app JSON serialization failed: {error}"))
    }

    async fn drain_pending_host_events(&mut self) -> Result<(), String> {
        loop {
            match tokio::time::timeout(Duration::from_millis(20), self.dtx.read_message(0)).await {
                Ok(Ok(message)) => self.note_host_event(&message),
                Ok(Err(error)) => return Err(format!("AX event read failed: {error:?}")),
                Err(_) => return Ok(()),
            }
        }
    }

    fn note_host_event(&mut self, message: &Message) {
        let Some(selector) = message.data.as_ref().and_then(Value::as_string) else {
            return;
        };
        if selector != "hostAppStateChanged:" {
            return;
        }
        let Ok(Some(payload)) = decode_first_argument(message) else {
            return;
        };
        let Some(event) = parse_app_state(&payload) else {
            return;
        };
        if std::env::var_os("POCKETPILOT_RECORD").is_some() {
            eprintln!(
                "pilot_bridge: app {} pid={} state={} {}",
                event.display_id, event.pid, event.state, event.description
            );
        }
        self.app_states.insert(event.pid, event);
    }

    fn current_frontmost(&self) -> Option<FrontmostApp> {
        choose_frontmost(self.app_states.values())
    }

    async fn disable_inspector_highlight(&mut self) -> Result<(), String> {
        for selector in INSPECTOR_HIGHLIGHT_OFF {
            self.invoke(selector, vec![AuxValue::archived_value(false)])
                .await?;
        }
        Ok(())
    }

    async fn invoke(&mut self, selector: &str, arguments: Vec<AuxValue>) -> Result<(), String> {
        self.dtx
            .call_method(0, Some(selector), Some(arguments), false)
            .await
            .map_err(|error| format!("AX selector {selector} failed: {error:?}"))
    }

    async fn request(&mut self, selector: &str, arguments: Vec<AuxValue>) -> Result<Value, String> {
        self.dtx
            .call_method(0, Some(selector), Some(arguments), true)
            .await
            .map_err(|error| format!("AX request {selector} failed: {error:?}"))?;
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                let message = self
                    .dtx
                    .read_message(0)
                    .await
                    .map_err(|error| format!("AX response read failed: {error:?}"))?;
                let incoming_selector = message.data.as_ref().and_then(Value::as_string);
                if incoming_selector.is_some_and(|value| value.starts_with("host")) {
                    self.note_host_event(&message);
                    continue;
                }
                if message
                    .data
                    .as_ref()
                    .and_then(Value::as_dictionary)
                    .is_some_and(|dictionary| dictionary.contains_key("NSCode"))
                {
                    let archive = message
                        .raw_data
                        .as_deref()
                        .and_then(|bytes| Value::from_reader(std::io::Cursor::new(bytes)).ok());
                    return Err(format!(
                        "AX request {selector} returned NSError: {archive:?}"
                    ));
                }
                if let Some(value) = message.data {
                    return Ok(value);
                }
                if let Some(value) = decode_first_argument(&message)? {
                    return Ok(value);
                }
                return Err(format!("AX request {selector} returned no value"));
            }
        })
        .await
        .map_err(|_| format!("AX request {selector} timed out"))?
    }

    async fn fetch_attribute(&mut self, element: Value, attribute: Value) -> Result<Value, String> {
        self.request(
            "deviceElement:valueForAttribute:",
            vec![
                AuxValue::archived_value(element),
                AuxValue::archived_value(attribute),
            ],
        )
        .await
    }

    async fn advance_focus(&mut self) -> Result<(), String> {
        self.move_next().await?;
        self.disable_inspector_highlight().await
    }

    async fn move_next(&mut self) -> Result<(), String> {
        let options = Value::Dictionary(Dictionary::from_iter([
            (
                "ObjectType".to_string(),
                Value::String("passthrough".to_string()),
            ),
            (
                "Value".to_string(),
                Value::Dictionary(Dictionary::from_iter([
                    ("allowNonAX".to_string(), passthrough(0_i64)),
                    ("direction".to_string(), passthrough(4_i64)),
                    ("includeContainers".to_string(), passthrough(1_i64)),
                ])),
            ),
        ]));
        self.invoke(
            "deviceInspectorMoveWithOptions:",
            vec![AuxValue::archived_value(options)],
        )
        .await
    }
}

async fn perform_dtx_handshake(
    dtx: &mut RemoteServerClient<Box<dyn ReadWrite>>,
) -> Result<(), String> {
    let capabilities = Value::Dictionary(Dictionary::from_iter([
        (
            "com.apple.private.DTXBlockCompression".to_string(),
            Value::from(0_i64),
        ),
        (
            "com.apple.private.DTXConnection".to_string(),
            Value::from(1_i64),
        ),
    ]));
    dtx.call_method(
        0,
        Some("_notifyOfPublishedCapabilities:"),
        Some(vec![AuxValue::archived_value(capabilities)]),
        false,
    )
    .await
    .map_err(|error| format!("AX DTX capability send failed: {error:?}"))?;

    tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            let message = dtx.read_message(0).await?;
            if message.data.as_ref().and_then(Value::as_string)
                == Some("_notifyOfPublishedCapabilities:")
            {
                return Ok::<(), idevice::IdeviceError>(());
            }
        }
    })
    .await
    .map_err(|_| "AX DTX capability handshake timed out".to_string())?
    .map_err(|error| format!("AX DTX capability handshake failed: {error:?}"))
}

async fn flush_initial_messages(dtx: &mut RemoteServerClient<Box<dyn ReadWrite>>) {
    for _ in 0..2 {
        if tokio::time::timeout(Duration::from_millis(300), dtx.read_message(0))
            .await
            .is_err()
        {
            break;
        }
    }
}

#[cfg(test)]
fn plist_preview(value: &Value, budget: usize) -> String {
    let mut out = String::new();
    write_plist_preview(value, &mut out);
    let count = out.chars().count();
    if count > budget {
        let truncated: String = out.chars().take(budget).collect();
        format!("{truncated}…")
    } else {
        out
    }
}

#[cfg(test)]
fn write_plist_preview(value: &Value, out: &mut String) {
    match value {
        Value::String(string) => {
            out.push('"');
            out.push_str(string);
            out.push('"');
        }
        Value::Integer(integer) => out.push_str(&integer.to_string()),
        Value::Real(real) => out.push_str(&real.to_string()),
        Value::Boolean(boolean) => out.push_str(if *boolean { "true" } else { "false" }),
        Value::Data(data) => out.push_str(&format!("<data {}B>", data.len())),
        Value::Array(array) => {
            out.push('[');
            for (index, item) in array.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write_plist_preview(item, out);
            }
            out.push(']');
        }
        Value::Dictionary(dictionary) => {
            out.push('{');
            for (index, (key, item)) in dictionary.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                out.push_str(key);
                out.push(':');
                write_plist_preview(item, out);
            }
            out.push('}');
        }
        other => out.push_str(&format!("{other:?}")),
    }
}

fn passthrough(value: impl Into<Value>) -> Value {
    Value::Dictionary(Dictionary::from_iter([
        (
            "ObjectType".to_string(),
            Value::String("passthrough".to_string()),
        ),
        ("Value".to_string(), value.into()),
    ]))
}

fn decode_first_argument(message: &Message) -> Result<Option<Value>, String> {
    let Some(argument) = message.aux.as_ref().and_then(|aux| aux.values.first()) else {
        return Ok(None);
    };
    let value = match argument {
        AuxValue::Array(bytes) => ns_keyed_archive::decode::from_bytes(bytes)
            .map_err(|error| format!("AX event archive decode failed: {error:?}"))?,
        AuxValue::String(value) => Value::String(value.clone()),
        AuxValue::U32(value) => Value::Integer((*value).into()),
        AuxValue::I64(value) => Value::Integer((*value).into()),
        AuxValue::Double(value) => Value::Real(*value),
        AuxValue::Null | AuxValue::PrimitiveDictionary(_) => return Ok(None),
    };
    Ok(Some(value))
}

fn find_attribute_descriptor<'a>(value: &'a Value, name: &str) -> Option<&'a Value> {
    match value {
        Value::Dictionary(dictionary) => {
            if dictionary.get("ObjectType").and_then(Value::as_string)
                == Some("AXAuditElementAttribute_v1")
                && string_field(value, "AttributeNameValue_v1").as_deref() == Some(name)
            {
                return Some(value);
            }
            dictionary
                .values()
                .find_map(|value| find_attribute_descriptor(value, name))
        }
        Value::Array(array) => array
            .iter()
            .find_map(|value| find_attribute_descriptor(value, name)),
        _ => None,
    }
}

fn find_field<'a>(value: &'a Value, key: &str) -> Option<&'a Value> {
    match value {
        Value::Dictionary(dictionary) => dictionary
            .get(key)
            .or_else(|| dictionary.values().find_map(|value| find_field(value, key))),
        Value::Array(array) => array.iter().find_map(|value| find_field(value, key)),
        _ => None,
    }
}

fn direct_field<'a>(value: &'a Value, key: &str) -> Option<&'a Value> {
    scalar(value)?.as_dictionary()?.get(key)
}

fn scalar(mut value: &Value) -> Option<&Value> {
    for _ in 0..8 {
        let Value::Dictionary(dictionary) = value else {
            return Some(value);
        };
        let Some(inner) = dictionary.get("Value") else {
            return Some(value);
        };
        value = inner;
    }
    None
}

fn string_field(value: &Value, key: &str) -> Option<String> {
    scalar(find_field(value, key)?)
        .and_then(Value::as_string)
        .map(ToOwned::to_owned)
}

fn direct_string_field(value: &Value, key: &str) -> Option<String> {
    scalar(direct_field(value, key)?)
        .and_then(Value::as_string)
        .map(ToOwned::to_owned)
}

fn direct_bool_field(value: &Value, key: &str) -> Option<bool> {
    scalar(direct_field(value, key)?).and_then(Value::as_boolean)
}

impl AppState {
    fn is_foreground(&self) -> bool {
        self.description.to_ascii_lowercase().contains("foreground")
    }

    fn is_ignored(&self) -> bool {
        let id = self.display_id.to_ascii_lowercase();
        if id == "com.apple.springboard" {
            return false;
        }
        id.contains("service")
            || id.contains("extension")
            || id.contains("activity")
            || id.contains("widget")
    }

    fn to_app(&self) -> FrontmostApp {
        let name = if !self.app_name.is_empty() && self.app_name != "Unknown" {
            self.app_name.clone()
        } else if !self.exec_name.is_empty() {
            self.exec_name.clone()
        } else {
            self.display_id
                .rsplit('.')
                .next()
                .unwrap_or(&self.display_id)
                .to_string()
        };
        FrontmostApp {
            name,
            bundle_id: self.display_id.clone(),
        }
    }
}

fn parse_app_state(payload: &Value) -> Option<AppState> {
    let display_id = string_field(payload, "displayID").filter(|id| !id.is_empty())?;
    let pid = find_field(payload, "pid")
        .and_then(first_integer)
        .filter(|pid| *pid > 0)?;
    let state = find_field(payload, "state")
        .and_then(first_integer)
        .unwrap_or(0);
    let description = string_field(payload, "state_description").unwrap_or_default();
    let time = find_field(payload, "mach_absolute_time")
        .and_then(first_integer)
        .or_else(|| {
            find_field(payload, "timestamp")
                .and_then(|value| find_field(value, "NS.time"))
                .and_then(first_integer)
        })
        .unwrap_or(0);
    Some(AppState {
        display_id,
        pid,
        state,
        description,
        time,
        exec_name: string_field(payload, "execName").unwrap_or_default(),
        app_name: string_field(payload, "appName").unwrap_or_default(),
    })
}

fn choose_frontmost<'a>(states: impl IntoIterator<Item = &'a AppState>) -> Option<FrontmostApp> {
    let states: Vec<&AppState> = states.into_iter().collect();
    if states.is_empty() {
        return None;
    }
    if let Some(foreground) = states
        .iter()
        .copied()
        .filter(|state| state.is_foreground() && !state.is_ignored())
        .max_by_key(|state| state.time)
    {
        return Some(foreground.to_app());
    }
    Some(FrontmostApp {
        name: "SpringBoard".into(),
        bundle_id: "com.apple.springboard".into(),
    })
}

fn first_integer(value: &Value) -> Option<i64> {
    let value = scalar(value)?;
    value
        .as_signed_integer()
        .or_else(|| {
            value
                .as_unsigned_integer()
                .and_then(|value| i64::try_from(value).ok())
        })
        .or_else(|| match value {
            Value::Dictionary(dictionary) => dictionary.values().find_map(first_integer),
            Value::Array(array) => array.iter().find_map(first_integer),
            _ => None,
        })
}

#[cfg(test)]
fn find_application(value: &Value, pid: i64) -> Option<FrontmostApp> {
    let value = scalar(value)?;
    match value {
        Value::Dictionary(dictionary) => {
            if application_pid(value) == Some(pid) {
                return application_identity(value);
            }
            dictionary
                .values()
                .find_map(|value| find_application(value, pid))
        }
        Value::Array(array) => array.iter().find_map(|value| find_application(value, pid)),
        _ => None,
    }
}

#[cfg(test)]
fn application_pid(value: &Value) -> Option<i64> {
    ["PidValue_v1", "pid"]
        .into_iter()
        .find_map(|key| find_field(value, key).and_then(first_integer))
}

#[cfg(test)]
fn application_identity(value: &Value) -> Option<FrontmostApp> {
    let name = ["DisplayNameValue_v1", "displayName", "name"]
        .into_iter()
        .find_map(|key| string_field(value, key))
        .filter(|name| !name.is_empty())?;
    let bundle_id = ["BundleIdentifierValue_v1", "bundleIdentifier", "bundle_id"]
        .into_iter()
        .find_map(|key| string_field(value, key))
        .filter(|bundle_id| !bundle_id.is_empty())?;
    Some(FrontmostApp { name, bundle_id })
}

fn token_hex(value: &Value) -> Option<String> {
    find_field(value, "PlatformElementValue_v1")
        .and_then(scalar)
        .and_then(Value::as_data)
        .map(hex)
}

fn node_token_hex(value: &Value) -> Option<String> {
    let element = direct_field(value, "AuditElementValue_v1")?;
    direct_field(element, "PlatformElementValue_v1")
        .and_then(scalar)
        .and_then(Value::as_data)
        .map(hex)
}

fn hex(bytes: &[u8]) -> String {
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        write!(output, "{byte:02X}").expect("writing to a String cannot fail");
    }
    output
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flattens_hierarchy_and_uses_accessibility_identifier() {
        let child = node(&[0x02], Some("child"), "Button", "Open", false, vec![]);
        let root = node(&[0x01], None, "Application", "Home", false, vec![child]);
        let mut builder = SnapshotBuilder::default();
        assert_eq!(builder.merge_tree(&root, 0).as_deref(), Some("01"));
        assert_eq!(builder.elements.len(), 2);
        assert_eq!(builder.elements[0].children, ["child"]);
        assert_eq!(builder.elements[1].token_hex, "02");
    }

    #[test]
    fn plist_preview_shows_keys_and_truncates() {
        let value = Value::Dictionary(Dictionary::from_iter([
            ("pid".to_string(), Value::Integer(501.into())),
            ("state".to_string(), Value::String("foreground".into())),
        ]));
        let preview = plist_preview(&value, 600);
        assert!(preview.contains("pid"));
        assert!(preview.contains("501"));
        assert!(plist_preview(&value, 8).ends_with('…'));
    }

    #[test]
    fn inspector_highlight_off_sends_visuals_and_highlight() {
        assert_eq!(
            INSPECTOR_HIGHLIGHT_OFF,
            ["deviceInspectorShowVisuals:", "deviceEnableHighlight:",]
        );
    }

    #[test]
    fn parses_app_state_payload() {
        let payload = app_state_payload(
            "com.apple.weather",
            501,
            4,
            "Foreground Running",
            100,
            "Weather",
            "Weather",
        );
        let event = parse_app_state(&payload).unwrap();
        assert_eq!(event.display_id, "com.apple.weather");
        assert_eq!(event.pid, 501);
        assert_eq!(event.state, 4);
        assert!(event.is_foreground());
        assert_eq!(
            event.to_app(),
            FrontmostApp {
                name: "Weather".into(),
                bundle_id: "com.apple.weather".into(),
            }
        );
    }

    #[test]
    fn chooses_latest_foreground_and_ignores_services() {
        let weather = AppState {
            display_id: "com.apple.weather".into(),
            pid: 501,
            state: 8,
            description: "Foreground Running".into(),
            time: 200,
            exec_name: "Weather".into(),
            app_name: "Unknown".into(),
        };
        let service = AppState {
            display_id: "com.apple.TGOnDeviceInferenceProviderService".into(),
            pid: 88,
            state: 4,
            description: "Background Running".into(),
            time: 300,
            exec_name: "TG".into(),
            app_name: "Unknown".into(),
        };
        let clock = AppState {
            display_id: "com.apple.mobiletimer".into(),
            pid: 502,
            state: 8,
            description: "Foreground Running".into(),
            time: 250,
            exec_name: "MobileTimer".into(),
            app_name: "Unknown".into(),
        };
        assert_eq!(
            choose_frontmost([&weather, &service, &clock]),
            Some(FrontmostApp {
                name: "MobileTimer".into(),
                bundle_id: "com.apple.mobiletimer".into(),
            })
        );
    }

    #[test]
    fn no_foreground_app_is_springboard() {
        let background = AppState {
            display_id: "com.apple.weather".into(),
            pid: 501,
            state: 2,
            description: "Background Task Suspended".into(),
            time: 1,
            exec_name: "Weather".into(),
            app_name: "Unknown".into(),
        };
        assert_eq!(
            choose_frontmost([&background]),
            Some(FrontmostApp {
                name: "SpringBoard".into(),
                bundle_id: "com.apple.springboard".into(),
            })
        );
        assert_eq!(choose_frontmost([] as [&AppState; 0]), None);
    }

    fn app_state_payload(
        display_id: &str,
        pid: i64,
        state: i64,
        description: &str,
        time: i64,
        exec_name: &str,
        app_name: &str,
    ) -> Value {
        Value::Dictionary(Dictionary::from_iter([
            (
                "name".to_string(),
                Value::String("SBApplicationNotificationStateChanged".into()),
            ),
            ("displayID".to_string(), passthrough(display_id)),
            ("pid".to_string(), passthrough(Value::Integer(pid.into()))),
            (
                "state".to_string(),
                passthrough(Value::Integer(state.into())),
            ),
            ("state_description".to_string(), passthrough(description)),
            (
                "mach_absolute_time".to_string(),
                passthrough(Value::Integer(time.into())),
            ),
            ("execName".to_string(), passthrough(exec_name)),
            ("appName".to_string(), passthrough(app_name)),
        ]))
    }

    #[test]
    fn finds_frontmost_app_from_audit_application_envelope() {
        let applications = Value::Array(vec![
            audit_application(83, "SpringBoard", "com.apple.springboard"),
            audit_application(501, "Settings", "com.apple.Preferences"),
        ]);
        assert_eq!(
            find_application(&applications, 501),
            Some(FrontmostApp {
                name: "Settings".to_string(),
                bundle_id: "com.apple.Preferences".to_string(),
            })
        );
        assert_eq!(find_application(&applications, 999), None);
    }

    #[test]
    fn finds_frontmost_app_pid_inside_passthrough() {
        assert_eq!(
            first_integer(&passthrough(Value::Integer(501.into()))),
            Some(501)
        );
    }

    fn audit_application(pid: i64, name: &str, bundle_id: &str) -> Value {
        Value::Dictionary(Dictionary::from_iter([
            (
                "ObjectType".to_string(),
                Value::String("AXAuditApplication_v1".to_string()),
            ),
            (
                "Value".to_string(),
                passthrough(Value::Dictionary(Dictionary::from_iter([
                    (
                        "PidValue_v1".to_string(),
                        passthrough(Value::Integer(pid.into())),
                    ),
                    ("DisplayNameValue_v1".to_string(), passthrough(name)),
                    (
                        "BundleIdentifierValue_v1".to_string(),
                        passthrough(bundle_id),
                    ),
                ]))),
            ),
        ]))
    }

    #[test]
    fn caps_hierarchy_depth() {
        let mut value = node(&[0xFF], None, "Button", "Leaf", false, vec![]);
        for byte in (0..=MAX_DEPTH as u8).rev() {
            value = node(&[byte], None, "Group", "Container", false, vec![value]);
        }
        let mut builder = SnapshotBuilder::default();
        builder.merge_tree(&value, 0);
        assert_eq!(builder.elements.len(), MAX_DEPTH + 1);
    }

    fn node(
        token: &[u8],
        identifier: Option<&str>,
        role: &str,
        description: &str,
        ignored: bool,
        children: Vec<Value>,
    ) -> Value {
        let mut element_fields = Dictionary::from_iter([(
            "PlatformElementValue_v1".to_string(),
            passthrough(Value::Data(token.to_vec())),
        )]);
        if let Some(identifier) = identifier {
            element_fields.insert(
                "AccessibilityIdentifier_v1".to_string(),
                passthrough(identifier),
            );
        }
        Value::Dictionary(Dictionary::from_iter([
            (
                "ObjectType".to_string(),
                Value::String("AXAuditNode_v1".to_string()),
            ),
            (
                "Value".to_string(),
                passthrough(Value::Dictionary(Dictionary::from_iter([
                    (
                        "AuditElementValue_v1".to_string(),
                        Value::Dictionary(Dictionary::from_iter([
                            (
                                "ObjectType".to_string(),
                                Value::String("AXAuditElement_v1".to_string()),
                            ),
                            (
                                "Value".to_string(),
                                passthrough(Value::Dictionary(element_fields)),
                            ),
                        ])),
                    ),
                    ("ChildrenValue_v1".to_string(), passthrough(children)),
                    (
                        "HumanReadableDescriptionValue_v1".to_string(),
                        passthrough(description),
                    ),
                    (
                        "HumanReadableRoleDescriptionValue_v1".to_string(),
                        passthrough(role),
                    ),
                    ("IsIgnoredValue_v1".to_string(), passthrough(ignored)),
                ]))),
            ),
        ]))
    }
}
