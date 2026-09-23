use std::collections::HashSet;
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
const ELEMENT_LIMIT: usize = 200;

pub(crate) struct AxClient {
    dtx: RemoteServerClient<Box<dyn ReadWrite>>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Snapshot {
    elements: Vec<Element>,
    complete: bool,
    geometry_available: bool,
    raw_sample: Option<serde_json::Value>,
}

#[derive(Serialize)]
struct Element {
    id: String,
    label: Option<String>,
    value: Option<String>,
    role: Option<String>,
    traits: Vec<String>,
    frame: Option<UnitFrame>,
}

#[derive(Serialize)]
struct UnitFrame {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
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
        Ok(Self { dtx })
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
        self.move_next().await?;

        let mut visited = HashSet::new();
        let mut elements = Vec::new();
        let mut raw_sample = None;
        let mut consecutive_timeouts = 0;
        let mut complete = false;

        while elements.len() < ELEMENT_LIMIT {
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
                    self.move_next().await?;
                    continue;
                }
            };

            if message.data.as_ref().and_then(Value::as_string)
                != Some("hostInspectorCurrentElementChanged:")
            {
                continue;
            }
            let Some(payload) = decode_first_argument(&message)? else {
                continue;
            };
            if raw_sample.is_none() {
                raw_sample = serde_json::to_value(&payload).ok();
            }
            let element = element_from_payload(&payload, elements.len());
            if !visited.insert(element.id.clone()) {
                complete = true;
                break;
            }
            elements.push(element);
            self.move_next().await?;
        }

        let geometry_available = elements.iter().any(|element| element.frame.is_some());
        serde_json::to_vec(&Snapshot {
            elements,
            complete,
            geometry_available,
            raw_sample,
        })
        .map_err(|error| format!("AX JSON serialization failed: {error}"))
    }

    async fn invoke(&mut self, selector: &str, arguments: Vec<AuxValue>) -> Result<(), String> {
        self.dtx
            .call_method(0, Some(selector), Some(arguments), false)
            .await
            .map_err(|error| format!("AX selector {selector} failed: {error:?}"))
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

fn element_from_payload(payload: &Value, index: usize) -> Element {
    let identifier = find_field(payload, "PlatformElementValue_v1")
        .and_then(scalar)
        .and_then(Value::as_data)
        .map(hex)
        .unwrap_or_else(|| format!("missing-{index}"));
    let label = string_field(payload, "CaptionTextValue_v1");
    let value = string_field(payload, "SpokenDescriptionValue_v1");
    let role = [
        "RoleValue_v1",
        "ElementRoleValue_v1",
        "RoleDescriptionValue_v1",
    ]
    .into_iter()
    .find_map(|key| string_field(payload, key));
    let traits = ["TraitsValue_v1", "TraitValue_v1"]
        .into_iter()
        .find_map(|key| find_field(payload, key).and_then(trait_strings))
        .unwrap_or_default();
    let frame = ["ElementRectValue_v1", "FrameValue_v1"]
        .into_iter()
        .find_map(|key| string_field(payload, key).and_then(|value| parse_unit_frame(&value)));
    Element {
        id: identifier,
        label,
        value,
        role,
        traits,
        frame,
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

fn trait_strings(value: &Value) -> Option<Vec<String>> {
    match scalar(value)? {
        Value::Array(values) => Some(
            values
                .iter()
                .filter_map(|value| scalar(value).and_then(Value::as_string))
                .map(ToOwned::to_owned)
                .collect(),
        ),
        Value::String(value) => Some(vec![value.clone()]),
        Value::Integer(value) => Some(vec![value.to_string()]),
        _ => None,
    }
}

fn parse_unit_frame(value: &str) -> Option<UnitFrame> {
    let numbers: Vec<f64> = value
        .split(|character: char| {
            !(character.is_ascii_digit()
                || character == '-'
                || character == '+'
                || character == '.'
                || character == 'e'
                || character == 'E')
        })
        .filter(|part| !part.is_empty())
        .filter_map(|part| part.parse().ok())
        .collect();
    let [x, y, width, height] = numbers.as_slice() else {
        return None;
    };
    let values = [*x, *y, *width, *height];
    if !values.iter().all(|value| value.is_finite())
        || *x < 0.0
        || *y < 0.0
        || *width < 0.0
        || *height < 0.0
        || *x + *width > 1.0
        || *y + *height > 1.0
    {
        return None;
    }
    Some(UnitFrame {
        x: *x,
        y: *y,
        width: *width,
        height: *height,
    })
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
    fn extracts_known_focus_fields_from_wrappers() {
        let payload = Value::Dictionary(Dictionary::from_iter([
            (
                "CaptionTextValue_v1".to_string(),
                passthrough("Wi-Fi".to_string()),
            ),
            (
                "ElementValue_v1".to_string(),
                Value::Dictionary(Dictionary::from_iter([(
                    "PlatformElementValue_v1".to_string(),
                    passthrough(Value::Data(vec![0xAB, 0xCD])),
                )])),
            ),
        ]));
        let element = element_from_payload(&payload, 0);
        assert_eq!(element.id, "ABCD");
        assert_eq!(element.label.as_deref(), Some("Wi-Fi"));
    }

    #[test]
    fn accepts_only_already_normalized_frames() {
        assert!(parse_unit_frame("{{0.1, 0.2}, {0.3, 0.4}}").is_some());
        assert!(parse_unit_frame("{{10, 20}, {30, 40}}").is_none());
    }
}
