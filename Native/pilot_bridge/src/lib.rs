mod ax;

use std::ffi::{CStr, CString, c_char, c_void};
use std::net::IpAddr;
use std::ptr;
use std::sync::Arc;
use std::time::Duration;

use idevice::core_device::{
    AppServiceClient, ButtonState, CallInfoBlob, DisplayServiceClient, ImageFormat,
    IndigoHidClient, ReportBlock, ScreenCaptureServiceClient, SenderReport,
    TOUCHSCREEN_STATE_CONTACT, TOUCHSCREEN_STATE_RELEASE, UniversalHidServiceClient,
    build_liveness, build_screen_audio_offer, build_screen_video_offer,
    build_start_audio_parameters, build_start_video_parameters, is_rtcp,
};
use idevice::core_device_proxy::CoreDeviceProxy;
use idevice::pairing_file::PairingFile;
use idevice::provider::TcpProvider;
use idevice::rsd::RsdHandshake;
use idevice::tcp::handle::{AdapterHandle, UdpSocketHandle};
use idevice::{IdeviceService, ReadWrite, RsdService};
use tokio::sync::mpsc;

const CLIENT_SUPPORTED_FEATURES: u64 = 140;
const KEY_LEFT_SHIFT: u64 = 0xE1;
const VIDEO_SENDER_PORT: u16 = 50_001;

/// Error categories returned by PilotBridge. The message carries operation-specific detail.
#[allow(non_camel_case_types)]
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PP_Error {
    Ok = 0,
    InvalidArgument = 1,
    SessionClosed = 2,
    Connection = 3,
    Service = 4,
    Unsupported = 5,
    Internal = 6,
}

/// Hardware buttons supported by `pp_press`.
#[allow(non_camel_case_types)]
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PP_Button {
    Home = 0,
    Lock = 1,
    VolumeUp = 2,
    VolumeDown = 3,
}

/// Called once when an operation finishes. `message` is valid only for the callback duration.
#[allow(non_camel_case_types)]
pub type PP_CompletionCallback =
    Option<unsafe extern "C" fn(ctx: *mut c_void, error: PP_Error, message: *const c_char)>;

/// Called once with borrowed bytes. `bytes` is valid only for the callback duration.
#[allow(non_camel_case_types)]
pub type PP_BytesCallback = Option<
    unsafe extern "C" fn(
        ctx: *mut c_void,
        bytes: *const u8,
        len: usize,
        error: PP_Error,
        message: *const c_char,
    ),
>;

/// Called once with the primary display's pixel dimensions.
#[allow(non_camel_case_types)]
pub type PP_SizeCallback = Option<
    unsafe extern "C" fn(
        ctx: *mut c_void,
        width: u32,
        height: u32,
        error: PP_Error,
        message: *const c_char,
    ),
>;

/// Opaque session. API calls on a session must not race `pp_session_close`.
#[allow(non_camel_case_types)]
pub struct PP_Session {
    commands: mpsc::UnboundedSender<Command>,
}

#[derive(Debug)]
struct BridgeError {
    code: PP_Error,
    message: String,
}

impl BridgeError {
    fn new(code: PP_Error, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }

    fn connection(context: &str, error: impl std::fmt::Debug) -> Self {
        Self::new(PP_Error::Connection, format!("{context}: {error:?}"))
    }

    fn service(context: &str, error: impl std::fmt::Debug) -> Self {
        Self::new(PP_Error::Service, format!("{context}: {error:?}"))
    }
}

#[derive(Clone, Copy)]
struct Completion {
    callback: PP_CompletionCallback,
    context: usize,
}

impl Completion {
    fn finish(self, result: Result<(), BridgeError>) {
        let Some(callback) = self.callback else {
            return;
        };
        match result {
            Ok(()) => unsafe { callback(self.context as *mut c_void, PP_Error::Ok, ptr::null()) },
            Err(error) => with_message(error.message, |message| unsafe {
                callback(self.context as *mut c_void, error.code, message)
            }),
        }
    }
}

#[derive(Clone, Copy)]
struct BytesCompletion {
    callback: PP_BytesCallback,
    context: usize,
}

impl BytesCompletion {
    fn finish(self, result: Result<Vec<u8>, BridgeError>) {
        let Some(callback) = self.callback else {
            return;
        };
        match result {
            Ok(bytes) => unsafe {
                callback(
                    self.context as *mut c_void,
                    bytes.as_ptr(),
                    bytes.len(),
                    PP_Error::Ok,
                    ptr::null(),
                )
            },
            Err(error) => with_message(error.message, |message| unsafe {
                callback(
                    self.context as *mut c_void,
                    ptr::null(),
                    0,
                    error.code,
                    message,
                )
            }),
        }
    }
}

#[derive(Clone, Copy)]
struct SizeCompletion {
    callback: PP_SizeCallback,
    context: usize,
}

impl SizeCompletion {
    fn finish(self, result: Result<(u32, u32), BridgeError>) {
        let Some(callback) = self.callback else {
            return;
        };
        match result {
            Ok((width, height)) => unsafe {
                callback(
                    self.context as *mut c_void,
                    width,
                    height,
                    PP_Error::Ok,
                    ptr::null(),
                )
            },
            Err(error) => with_message(error.message, |message| unsafe {
                callback(self.context as *mut c_void, 0, 0, error.code, message)
            }),
        }
    }
}

enum Command {
    Screenshot(BytesCompletion),
    Tap {
        x: f64,
        y: f64,
        completion: Completion,
    },
    LongPress {
        x: f64,
        y: f64,
        duration_ms: u32,
        completion: Completion,
    },
    Swipe {
        x0: f64,
        y0: f64,
        x1: f64,
        y1: f64,
        duration_ms: u32,
        completion: Completion,
    },
    TypeText {
        text: String,
        completion: Completion,
    },
    Press {
        button: PP_Button,
        completion: Completion,
    },
    LaunchApp {
        bundle_id: String,
        completion: Completion,
    },
    ScreenSize(SizeCompletion),
    AxSnapshot(BytesCompletion),
    AxHitTest {
        x: f64,
        y: f64,
        completion: BytesCompletion,
    },
    Shutdown,
}

struct ConnectedSession {
    screenshot: ScreenCaptureServiceClient<Box<dyn ReadWrite>>,
    touch: UniversalHidServiceClient<Box<dyn ReadWrite>>,
    keyboard: IndigoHidClient<Box<dyn ReadWrite>>,
    apps: AppServiceClient<Box<dyn ReadWrite>>,
    display: DisplayServiceClient<Box<dyn ReadWrite>>,
    ax: Result<ax::AxClient, String>,
    _adapter: AdapterHandle,
    _handshake: RsdHandshake,
    screen_size: Option<(u32, u32)>,
}

impl ConnectedSession {
    async fn connect(pairing_bytes: &[u8], host_ip: &str) -> Result<Self, BridgeError> {
        let pairing_file = PairingFile::from_bytes(pairing_bytes)
            .map_err(|error| BridgeError::connection("invalid pairing plist", error))?;
        let address: IpAddr = host_ip.parse().map_err(|error| {
            BridgeError::new(
                PP_Error::InvalidArgument,
                format!("invalid host IP: {error}"),
            )
        })?;
        let provider = TcpProvider {
            addr: address,
            scope_id: None,
            pairing_file,
            label: "PocketPilot".into(),
        };

        let proxy = CoreDeviceProxy::connect(&provider)
            .await
            .map_err(|error| BridgeError::connection("CoreDeviceProxy connection failed", error))?;
        let rsd_port = proxy.tunnel_info().server_rsd_port;
        let mut adapter = proxy
            .create_software_tunnel()
            .map_err(|error| BridgeError::connection("software tunnel creation failed", error))?
            .to_async_handle();
        let stream = adapter
            .connect(rsd_port)
            .await
            .map_err(|error| BridgeError::connection("RSD connection failed", error))?;
        let mut handshake = RsdHandshake::new(stream)
            .await
            .map_err(|error| BridgeError::connection("RSD handshake failed", error))?;

        let screenshot = ScreenCaptureServiceClient::connect_rsd(&mut adapter, &mut handshake)
            .await
            .map_err(|error| BridgeError::service("screenshot service unavailable", error))?;
        let apps = AppServiceClient::connect_rsd(&mut adapter, &mut handshake)
            .await
            .map_err(|error| BridgeError::service("app service unavailable", error))?;
        let display = start_display_gate(&mut adapter, &mut handshake).await?;

        // dtuhidd accepts connections before this point but drops every event until
        // displayservice has established the screen-sharing authentication gate.
        tokio::time::sleep(Duration::from_millis(300)).await;
        let touch = UniversalHidServiceClient::connect_rsd(&mut adapter, &mut handshake)
            .await
            .map_err(|error| BridgeError::service("touch service unavailable", error))?;
        let keyboard = IndigoHidClient::connect_rsd(&mut adapter, &mut handshake)
            .await
            .map_err(|error| BridgeError::service("HID service unavailable", error))?;
        let ax = ax::AxClient::connect(&mut adapter, &handshake).await;

        Ok(Self {
            screenshot,
            touch,
            keyboard,
            apps,
            display,
            ax,
            _adapter: adapter,
            _handshake: handshake,
            screen_size: None,
        })
    }

    async fn take_screenshot(&mut self) -> Result<Vec<u8>, BridgeError> {
        let png = self
            .screenshot
            .take_screenshot(None, ImageFormat::Png)
            .await
            .map_err(|error| BridgeError::service("screenshot failed", error))?;
        self.screen_size = Some(png_dimensions(&png)?);
        Ok(png)
    }

    async fn size(&mut self) -> Result<(u32, u32), BridgeError> {
        if let Some(size) = self.screen_size {
            return Ok(size);
        }
        let png = self.take_screenshot().await?;
        png_dimensions(&png)
    }

    fn point(x: f64, y: f64) -> Result<(u16, u16), BridgeError> {
        validate_normalized(x, "x")?;
        validate_normalized(y, "y")?;
        Ok((scale_coordinate(x), scale_coordinate(y)))
    }

    async fn run_command(&mut self, command: Command) -> bool {
        match command {
            Command::Screenshot(completion) => completion.finish(self.take_screenshot().await),
            Command::Tap { x, y, completion } => {
                let result = async {
                    let (x, y) = Self::point(x, y)?;
                    self.touch
                        .tap(x, y)
                        .await
                        .map_err(|error| BridgeError::service("tap failed", error))
                }
                .await;
                completion.finish(result);
            }
            Command::LongPress {
                x,
                y,
                duration_ms,
                completion,
            } => {
                let result = async {
                    let (x, y) = Self::point(x, y)?;
                    self.touch
                        .send_touchscreen(TOUCHSCREEN_STATE_CONTACT, x, y, None)
                        .await
                        .map_err(|error| {
                            BridgeError::service("long press began unsuccessfully", error)
                        })?;
                    tokio::time::sleep(Duration::from_millis(duration_ms.into())).await;
                    self.touch
                        .send_touchscreen(TOUCHSCREEN_STATE_RELEASE, x, y, None)
                        .await
                        .map_err(|error| BridgeError::service("long press release failed", error))
                }
                .await;
                completion.finish(result);
            }
            Command::Swipe {
                x0,
                y0,
                x1,
                y1,
                duration_ms,
                completion,
            } => {
                let result = async {
                    let (x0, y0) = Self::point(x0, y0)?;
                    let (x1, y1) = Self::point(x1, y1)?;
                    let steps = duration_ms.div_ceil(16).max(1);
                    let delay_ms = u64::from(duration_ms / steps);
                    self.touch
                        .drag(x0, y0, x1, y1, steps, delay_ms)
                        .await
                        .map_err(|error| BridgeError::service("swipe failed", error))
                }
                .await;
                completion.finish(result);
            }
            Command::TypeText { text, completion } => {
                completion.finish(type_text(&mut self.keyboard, &text).await);
            }
            Command::Press { button, completion } => {
                completion.finish(press_button(&mut self.keyboard, button).await);
            }
            Command::LaunchApp {
                bundle_id,
                completion,
            } => {
                let result = self
                    .apps
                    .launch_application(bundle_id, &[], false, false, None, None, None)
                    .await
                    .map(|_| ())
                    .map_err(|error| BridgeError::service("app launch failed", error));
                completion.finish(result);
            }
            Command::ScreenSize(completion) => completion.finish(self.size().await),
            Command::AxSnapshot(completion) => {
                let result = match &mut self.ax {
                    Ok(ax) => ax
                        .snapshot()
                        .await
                        .map_err(|error| BridgeError::new(PP_Error::Service, error)),
                    Err(error) => Err(BridgeError::new(
                        PP_Error::Service,
                        format!("accessibility service unavailable: {error}"),
                    )),
                };
                completion.finish(result);
            }
            Command::AxHitTest { x, y, completion } => {
                let result = match &mut self.ax {
                    Ok(ax) => ax
                        .hit_test(x, y)
                        .await
                        .map_err(|error| BridgeError::new(PP_Error::Service, error)),
                    Err(error) => Err(BridgeError::new(
                        PP_Error::Service,
                        format!("accessibility service unavailable: {error}"),
                    )),
                };
                completion.finish(result);
            }
            Command::Shutdown => {
                let _ = self.display.stop_media_stream().await;
                return false;
            }
        }
        true
    }
}

async fn run_session(
    pairing_bytes: Vec<u8>,
    host_ip: String,
    open_completion: Completion,
    mut commands: mpsc::UnboundedReceiver<Command>,
) {
    let connected = ConnectedSession::connect(&pairing_bytes, &host_ip).await;
    match connected {
        Ok(mut session) => {
            open_completion.finish(Ok(()));
            while let Some(command) = commands.recv().await {
                if !session.run_command(command).await {
                    break;
                }
            }
        }
        Err(error) => {
            let failure_message = error.message.clone();
            open_completion.finish(Err(error));
            while let Some(command) = commands.recv().await {
                if matches!(command, Command::Shutdown) {
                    break;
                }
                finish_unavailable(command, &failure_message);
            }
        }
    }
}

fn finish_unavailable(command: Command, detail: &str) {
    let error = || {
        BridgeError::new(
            PP_Error::SessionClosed,
            format!("session did not open: {detail}"),
        )
    };
    match command {
        Command::Screenshot(completion)
        | Command::AxSnapshot(completion)
        | Command::AxHitTest { completion, .. } => completion.finish(Err(error())),
        Command::ScreenSize(completion) => completion.finish(Err(error())),
        Command::Tap { completion, .. }
        | Command::LongPress { completion, .. }
        | Command::Swipe { completion, .. }
        | Command::TypeText { completion, .. }
        | Command::Press { completion, .. }
        | Command::LaunchApp { completion, .. } => completion.finish(Err(error())),
        Command::Shutdown => {}
    }
}

async fn start_display_gate(
    adapter: &mut AdapterHandle,
    handshake: &mut RsdHandshake,
) -> Result<DisplayServiceClient<Box<dyn ReadWrite>>, BridgeError> {
    let mut client = DisplayServiceClient::connect_rsd(adapter, handshake)
        .await
        .map_err(|error| BridgeError::service("display service unavailable", error))?;
    let audio = adapter
        .bind_udp(0)
        .await
        .map_err(|error| BridgeError::connection("audio UDP bind failed", error))?;
    let video = adapter
        .bind_udp(0)
        .await
        .map_err(|error| BridgeError::connection("video UDP bind failed", error))?;
    let rtcp = match video.local_port().checked_add(1) {
        Some(port) => adapter.bind_udp(port).await.ok(),
        None => None,
    };
    let receiver_ip = adapter.host_ip().to_string();
    let sender_ip = adapter.peer_ip().to_string();
    let session_id = uuid::Uuid::new_v4();
    let our_ssrc = uuid::Uuid::new_v4().as_u128() as u32;

    let audio_offer = build_screen_audio_offer(
        &uuid::Uuid::new_v4().to_string().to_uppercase(),
        &call_info(),
    )
    .map_err(|error| BridgeError::service("audio offer creation failed", error))?;
    let audio_parameters = build_start_audio_parameters(
        &receiver_ip,
        audio.local_port(),
        &sender_ip,
        50_000,
        audio_offer,
        CLIENT_SUPPORTED_FEATURES,
        session_id,
    );
    client
        .start_media_stream(audio_parameters)
        .await
        .map_err(|error| BridgeError::service("audio media stream failed", error))?;

    let video_offer = build_screen_video_offer(
        &uuid::Uuid::new_v4().to_string().to_uppercase(),
        &call_info(),
        our_ssrc,
    )
    .map_err(|error| BridgeError::service("video offer creation failed", error))?;
    let video_parameters = build_start_video_parameters(
        &receiver_ip,
        video.local_port(),
        &sender_ip,
        VIDEO_SENDER_PORT,
        video_offer,
        CLIENT_SUPPORTED_FEATURES,
        1,
        session_id,
    );
    client
        .start_media_stream(video_parameters)
        .await
        .map_err(|error| BridgeError::service("video media stream failed", error))?;

    // The stream is only an authentication gate here. Drain media so its unbounded
    // software-stack channels cannot grow, and keep AVConference alive with RTCP.
    tokio::spawn(async move { while audio.recv().await.is_ok() {} });
    keep_display_stream_alive(video, rtcp, adapter.host_ip().to_string(), our_ssrc);
    Ok(client)
}

#[derive(Default)]
struct RtcpState {
    media_ssrc: Option<u32>,
    mux_port: Option<u16>,
    separate_port: Option<u16>,
}

fn keep_display_stream_alive(
    video: UdpSocketHandle,
    rtcp: Option<UdpSocketHandle>,
    host_ip: String,
    our_ssrc: u32,
) {
    let video = Arc::new(video);
    let rtcp = rtcp.map(Arc::new);
    let state = Arc::new(tokio::sync::Mutex::new(RtcpState::default()));

    let video_receiver = video.clone();
    let video_state = state.clone();
    tokio::spawn(async move {
        while let Ok(datagram) = video_receiver.recv().await {
            let mut state = video_state.lock().await;
            if is_rtcp(&datagram.data) {
                state.mux_port = Some(datagram.source_port);
                if let Some(report) = SenderReport::parse_first(&datagram.data) {
                    state.media_ssrc = Some(report.ssrc);
                }
            } else if let Some(ssrc) = rtp_ssrc(&datagram.data) {
                state.media_ssrc.get_or_insert(ssrc);
            }
        }
    });

    if let Some(rtcp_receiver) = rtcp.clone() {
        let rtcp_state = state.clone();
        tokio::spawn(async move {
            while let Ok(datagram) = rtcp_receiver.recv().await {
                if !is_rtcp(&datagram.data) {
                    continue;
                }
                let mut state = rtcp_state.lock().await;
                state.separate_port = Some(datagram.source_port);
                if let Some(report) = SenderReport::parse_first(&datagram.data) {
                    state.media_ssrc = Some(report.ssrc);
                }
            }
        });
    }

    tokio::spawn(async move {
        let cname = format!("devicehub@{host_ip}");
        let mut tick = tokio::time::interval(Duration::from_secs(1));
        loop {
            tick.tick().await;
            let (media_ssrc, mux_port, separate_port) = {
                let state = state.lock().await;
                (state.media_ssrc, state.mux_port, state.separate_port)
            };
            let blocks = media_ssrc
                .map(|source_ssrc| ReportBlock {
                    source_ssrc,
                    ..ReportBlock::default()
                })
                .into_iter()
                .collect::<Vec<_>>();
            let packet = build_liveness(our_ssrc, &cname, &blocks);
            let _ = video
                .send_to(mux_port.unwrap_or(VIDEO_SENDER_PORT), packet.clone())
                .await;
            if let Some(rtcp) = &rtcp {
                let _ = rtcp
                    .send_to(
                        separate_port.unwrap_or(VIDEO_SENDER_PORT + 1),
                        packet.clone(),
                    )
                    .await;
            }
        }
    });
}

fn rtp_ssrc(packet: &[u8]) -> Option<u32> {
    if packet.len() < 12 || packet[0] >> 6 != 2 {
        return None;
    }
    Some(u32::from_be_bytes(packet[8..12].try_into().ok()?))
}

fn call_info() -> CallInfoBlob {
    CallInfoBlob {
        call_id: 0,
        client_version: 1,
        device_type: "Mac17,7".into(),
        framework_version: "2205.3.1".into(),
        os_version: "25F71".into(),
        device_name: None,
        audio_device_uid: None,
    }
}

async fn type_text(
    keyboard: &mut IndigoHidClient<Box<dyn ReadWrite>>,
    text: &str,
) -> Result<(), BridgeError> {
    let keys: Vec<_> = text
        .chars()
        .map(|character| {
            ascii_to_usage(character).ok_or_else(|| {
                BridgeError::new(
                    PP_Error::Unsupported,
                    format!("cannot type non-US-keyboard character {character:?}"),
                )
            })
        })
        .collect::<Result<_, _>>()?;

    for (usage, shift) in keys {
        if shift {
            send_key(keyboard, KEY_LEFT_SHIFT, ButtonState::Down).await?;
        }
        send_key(keyboard, usage, ButtonState::Down).await?;
        send_key(keyboard, usage, ButtonState::Up).await?;
        if shift {
            send_key(keyboard, KEY_LEFT_SHIFT, ButtonState::Up).await?;
        }
        tokio::time::sleep(Duration::from_millis(12)).await;
    }
    Ok(())
}

async fn send_key(
    keyboard: &mut IndigoHidClient<Box<dyn ReadWrite>>,
    usage: u64,
    state: ButtonState,
) -> Result<(), BridgeError> {
    keyboard
        .send_keyboard(usage, state)
        .await
        .map_err(|error| BridgeError::service("keyboard input failed", error))
}

async fn press_button(
    keyboard: &mut IndigoHidClient<Box<dyn ReadWrite>>,
    button: PP_Button,
) -> Result<(), BridgeError> {
    let (usage_code, hold_ms) = match button {
        PP_Button::Home => (0x40, 80),
        PP_Button::Lock => (0x30, 200),
        PP_Button::VolumeUp => (0xE9, 80),
        PP_Button::VolumeDown => (0xEA, 80),
    };
    keyboard
        .send_button(0x0C, usage_code, ButtonState::Down)
        .await
        .map_err(|error| BridgeError::service("button press failed", error))?;
    tokio::time::sleep(Duration::from_millis(hold_ms)).await;
    keyboard
        .send_button(0x0C, usage_code, ButtonState::Up)
        .await
        .map_err(|error| BridgeError::service("button release failed", error))
}

fn validate_normalized(value: f64, name: &str) -> Result<(), BridgeError> {
    if value.is_finite() && (0.0..=1.0).contains(&value) {
        Ok(())
    } else {
        Err(BridgeError::new(
            PP_Error::InvalidArgument,
            format!("{name} must be finite and within 0...1"),
        ))
    }
}

fn scale_coordinate(value: f64) -> u16 {
    (value * f64::from(u16::MAX)).round() as u16
}

fn png_dimensions(bytes: &[u8]) -> Result<(u32, u32), BridgeError> {
    const PNG_IHDR_PREFIX: &[u8] = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR";
    if bytes.len() < 24 || &bytes[..16] != PNG_IHDR_PREFIX {
        return Err(BridgeError::new(
            PP_Error::Service,
            "screenshot response is not a PNG with an IHDR chunk",
        ));
    }
    let width = u32::from_be_bytes(bytes[16..20].try_into().expect("fixed-width slice"));
    let height = u32::from_be_bytes(bytes[20..24].try_into().expect("fixed-width slice"));
    if width == 0 || height == 0 {
        return Err(BridgeError::new(
            PP_Error::Service,
            "screenshot has zero dimensions",
        ));
    }
    Ok((width, height))
}

fn ascii_to_usage(character: char) -> Option<(u64, bool)> {
    Some(match character {
        'a'..='z' => (0x04 + u64::from(character as u8 - b'a'), false),
        'A'..='Z' => (0x04 + u64::from(character as u8 - b'A'), true),
        '1'..='9' => (0x1E + u64::from(character as u8 - b'1'), false),
        '0' => (0x27, false),
        '\n' => (0x28, false),
        '\t' => (0x2B, false),
        ' ' => (0x2C, false),
        '!' => (0x1E, true),
        '@' => (0x1F, true),
        '#' => (0x20, true),
        '$' => (0x21, true),
        '%' => (0x22, true),
        '^' => (0x23, true),
        '&' => (0x24, true),
        '*' => (0x25, true),
        '(' => (0x26, true),
        ')' => (0x27, true),
        '-' => (0x2D, false),
        '_' => (0x2D, true),
        '=' => (0x2E, false),
        '+' => (0x2E, true),
        '[' => (0x2F, false),
        '{' => (0x2F, true),
        ']' => (0x30, false),
        '}' => (0x30, true),
        '\\' => (0x31, false),
        '|' => (0x31, true),
        ';' => (0x33, false),
        ':' => (0x33, true),
        '\'' => (0x34, false),
        '"' => (0x34, true),
        '`' => (0x35, false),
        '~' => (0x35, true),
        ',' => (0x36, false),
        '<' => (0x36, true),
        '.' => (0x37, false),
        '>' => (0x37, true),
        '/' => (0x38, false),
        '?' => (0x38, true),
        _ => return None,
    })
}

fn with_message(message: String, body: impl FnOnce(*const c_char)) {
    let message = CString::new(message.replace('\0', " ")).expect("NUL bytes replaced");
    body(message.as_ptr());
}

fn completion(callback: PP_CompletionCallback, context: *mut c_void) -> Completion {
    Completion {
        callback,
        context: context as usize,
    }
}

fn bytes_completion(callback: PP_BytesCallback, context: *mut c_void) -> BytesCompletion {
    BytesCompletion {
        callback,
        context: context as usize,
    }
}

fn size_completion(callback: PP_SizeCallback, context: *mut c_void) -> SizeCompletion {
    SizeCompletion {
        callback,
        context: context as usize,
    }
}

fn send_command(session: *mut PP_Session, command: Command) {
    if session.is_null() {
        finish_unavailable(command, "session pointer is null");
        return;
    }
    let sender = unsafe { &*session }.commands.clone();
    if let Err(error) = sender.send(command) {
        finish_unavailable(error.0, "session is closed");
    }
}

/// Opens a session asynchronously. The returned handle is owned by the caller and must be closed.
/// The callback reports whether setup completed; commands enqueued before it fires execute afterward.
///
/// `pairing_plist_bytes` must point to `len` readable bytes and `host_ip` must be NUL-terminated.
///
/// # Safety
///
/// Input pointers must remain readable for the duration of this call. `context` must remain valid
/// until the callback returns, according to the caller's own callback contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pp_session_open(
    pairing_plist_bytes: *const u8,
    len: usize,
    host_ip: *const c_char,
    callback: PP_CompletionCallback,
    context: *mut c_void,
) -> *mut PP_Session {
    let open_completion = completion(callback, context);
    if pairing_plist_bytes.is_null() || len == 0 || host_ip.is_null() {
        open_completion.finish(Err(BridgeError::new(
            PP_Error::InvalidArgument,
            "pairing plist and host IP are required",
        )));
        return ptr::null_mut();
    }

    let pairing_bytes = unsafe { std::slice::from_raw_parts(pairing_plist_bytes, len) }.to_vec();
    let host_ip = match unsafe { CStr::from_ptr(host_ip) }.to_str() {
        Ok(value) => value.to_owned(),
        Err(_) => {
            open_completion.finish(Err(BridgeError::new(
                PP_Error::InvalidArgument,
                "host IP is not valid UTF-8",
            )));
            return ptr::null_mut();
        }
    };

    let (sender, receiver) = mpsc::unbounded_channel();
    let thread = std::thread::Builder::new()
        .name("PocketPilot session".into())
        .spawn(move || {
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build();
            match runtime {
                Ok(runtime) => runtime.block_on(run_session(
                    pairing_bytes,
                    host_ip,
                    open_completion,
                    receiver,
                )),
                Err(error) => open_completion.finish(Err(BridgeError::new(
                    PP_Error::Internal,
                    format!("Tokio runtime creation failed: {error}"),
                ))),
            }
        });
    if let Err(error) = thread {
        completion(callback, context).finish(Err(BridgeError::new(
            PP_Error::Internal,
            format!("session thread creation failed: {error}"),
        )));
        return ptr::null_mut();
    }

    Box::into_raw(Box::new(PP_Session { commands: sender }))
}

/// Requests asynchronous shutdown and releases the session handle. Does not wait for teardown.
///
/// # Safety
///
/// `session` must be null or a live handle returned by `pp_session_open`, and may be closed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pp_session_close(session: *mut PP_Session) {
    if session.is_null() {
        return;
    }
    let session = unsafe { Box::from_raw(session) };
    let _ = session.commands.send(Command::Shutdown);
}

/// Captures the primary display as PNG bytes.
///
/// # Safety
///
/// `session` must remain live until this call returns. Callback state must outlive the callback.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pp_screenshot(
    session: *mut PP_Session,
    callback: PP_BytesCallback,
    context: *mut c_void,
) {
    send_command(
        session,
        Command::Screenshot(bytes_completion(callback, context)),
    );
}

/// Taps a native-portrait normalized point on the primary display.
///
/// # Safety
///
/// `session` must remain live until this call returns. Callback state must outlive the callback.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pp_tap(
    session: *mut PP_Session,
    x: f64,
    y: f64,
    callback: PP_CompletionCallback,
    context: *mut c_void,
) {
    send_command(
        session,
        Command::Tap {
            x,
            y,
            completion: completion(callback, context),
        },
    );
}

/// Holds a native-portrait normalized point for `duration_ms` milliseconds.
///
/// # Safety
///
/// `session` must remain live until this call returns. Callback state must outlive the callback.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pp_long_press(
    session: *mut PP_Session,
    x: f64,
    y: f64,
    duration_ms: u32,
    callback: PP_CompletionCallback,
    context: *mut c_void,
) {
    send_command(
        session,
        Command::LongPress {
            x,
            y,
            duration_ms,
            completion: completion(callback, context),
        },
    );
}

/// Swipes between native-portrait normalized points over `duration_ms` milliseconds.
///
/// # Safety
///
/// `session` must remain live until this call returns. Callback state must outlive the callback.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pp_swipe(
    session: *mut PP_Session,
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
    duration_ms: u32,
    callback: PP_CompletionCallback,
    context: *mut c_void,
) {
    send_command(
        session,
        Command::Swipe {
            x0,
            y0,
            x1,
            y1,
            duration_ms,
            completion: completion(callback, context),
        },
    );
}

/// Copies `utf8` before returning.
///
/// # Safety
///
/// `session` must remain live until this call returns, `utf8` must be NUL-terminated, and callback
/// state must outlive the callback.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pp_type_text(
    session: *mut PP_Session,
    utf8: *const c_char,
    callback: PP_CompletionCallback,
    context: *mut c_void,
) {
    let completion = completion(callback, context);
    if utf8.is_null() {
        completion.finish(Err(BridgeError::new(
            PP_Error::InvalidArgument,
            "text pointer is null",
        )));
        return;
    }
    let text = match unsafe { CStr::from_ptr(utf8) }.to_str() {
        Ok(value) => value.to_owned(),
        Err(_) => {
            completion.finish(Err(BridgeError::new(
                PP_Error::InvalidArgument,
                "text is not valid UTF-8",
            )));
            return;
        }
    };
    send_command(session, Command::TypeText { text, completion });
}

/// Presses and releases a supported hardware button.
///
/// # Safety
///
/// `session` must remain live until this call returns. Callback state must outlive the callback.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pp_press(
    session: *mut PP_Session,
    button: PP_Button,
    callback: PP_CompletionCallback,
    context: *mut c_void,
) {
    send_command(
        session,
        Command::Press {
            button,
            completion: completion(callback, context),
        },
    );
}

/// Copies `bundle_id` before returning and launches without terminating an existing instance.
///
/// # Safety
///
/// `session` must remain live until this call returns, `bundle_id` must be NUL-terminated, and
/// callback state must outlive the callback.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pp_launch_app(
    session: *mut PP_Session,
    bundle_id: *const c_char,
    callback: PP_CompletionCallback,
    context: *mut c_void,
) {
    let completion = completion(callback, context);
    if bundle_id.is_null() {
        completion.finish(Err(BridgeError::new(
            PP_Error::InvalidArgument,
            "bundle identifier pointer is null",
        )));
        return;
    }
    let bundle_id = match unsafe { CStr::from_ptr(bundle_id) }.to_str() {
        Ok(value) if !value.is_empty() => value.to_owned(),
        Ok(_) => {
            completion.finish(Err(BridgeError::new(
                PP_Error::InvalidArgument,
                "bundle identifier is empty",
            )));
            return;
        }
        Err(_) => {
            completion.finish(Err(BridgeError::new(
                PP_Error::InvalidArgument,
                "bundle identifier is not valid UTF-8",
            )));
            return;
        }
    };
    send_command(
        session,
        Command::LaunchApp {
            bundle_id,
            completion,
        },
    );
}

/// Returns the primary display size in pixels, capturing one screenshot if the size is uncached.
///
/// # Safety
///
/// `session` must remain live until this call returns. Callback state must outlive the callback.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pp_screen_size(
    session: *mut PP_Session,
    callback: PP_SizeCallback,
    context: *mut c_void,
) {
    send_command(
        session,
        Command::ScreenSize(size_completion(callback, context)),
    );
}

/// Returns a JSON accessibility hierarchy snapshot.
///
/// The top-level JSON value is an array of nodes. Each node includes `id`, `token_hex`, `role`,
/// `label`, `value`, `traits`, `children`, and `ignored`. Traversal is capped at depth 12 and 300
/// nodes. Geometry is intentionally supplied separately by OCR and `pp_ax_hit_test`.
///
/// # Safety
///
/// `session` must remain live until this call returns. Callback state must outlive the callback.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pp_ax_snapshot(
    session: *mut PP_Session,
    callback: PP_BytesCallback,
    context: *mut c_void,
) {
    send_command(
        session,
        Command::AxSnapshot(bytes_completion(callback, context)),
    );
}

/// Returns the uppercase hexadecimal accessibility token at a normalized display coordinate.
///
/// Coordinates use portrait display space and must each be finite and in the inclusive range
/// 0...1. The callback bytes contain UTF-8 text and are valid only for the callback duration.
///
/// # Safety
///
/// `session` must remain live until this call returns. Callback state must outlive the callback.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pp_ax_hit_test(
    session: *mut PP_Session,
    x: f64,
    y: f64,
    callback: PP_BytesCallback,
    context: *mut c_void,
) {
    send_command(
        session,
        Command::AxHitTest {
            x,
            y,
            completion: bytes_completion(callback, context),
        },
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_png_dimensions() {
        let mut png = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR".to_vec();
        png.extend_from_slice(&1179_u32.to_be_bytes());
        png.extend_from_slice(&2556_u32.to_be_bytes());
        assert_eq!(png_dimensions(&png).unwrap(), (1179, 2556));
    }

    #[test]
    fn scales_normalized_coordinates_to_hid_range() {
        assert_eq!(scale_coordinate(0.0), 0);
        assert_eq!(scale_coordinate(0.5), 32_768);
        assert_eq!(scale_coordinate(1.0), 65_535);
    }

    #[test]
    fn rejects_out_of_range_coordinates() {
        assert!(validate_normalized(-0.01, "x").is_err());
        assert!(validate_normalized(1.01, "x").is_err());
        assert!(validate_normalized(f64::NAN, "x").is_err());
    }

    #[test]
    fn maps_us_keyboard_characters() {
        assert_eq!(ascii_to_usage('a'), Some((0x04, false)));
        assert_eq!(ascii_to_usage('A'), Some((0x04, true)));
        assert_eq!(ascii_to_usage('?'), Some((0x38, true)));
        assert_eq!(ascii_to_usage('é'), None);
    }

    #[test]
    fn reads_rtp_ssrc() {
        let packet = [0x80, 100, 0, 1, 0, 0, 0, 0, 0x12, 0x34, 0x56, 0x78];
        assert_eq!(rtp_ssrc(&packet), Some(0x1234_5678));
        assert_eq!(rtp_ssrc(&packet[..11]), None);
    }
}
