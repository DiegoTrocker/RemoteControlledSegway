import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';

enum ControlMode { arrows, throttleWheel, gyro }

enum AppScreen { home, modeSelection, drive, settings }

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
        textTheme: ThemeData.dark().textTheme.apply(
          bodyColor: Colors.white,
          displayColor: Colors.white,
        ),
      ),
      home: const SegwayControllerPage(),
    );
  }
}

class SegwayControllerPage extends StatefulWidget {
  const SegwayControllerPage({super.key});

  @override
  State<SegwayControllerPage> createState() => _SegwayControllerPageState();
}

class _SegwayControllerPageState extends State<SegwayControllerPage> {
  final _logController = ScrollController();
  BluetoothConnection? _connection;
  BluetoothDevice? _selectedDevice;
  List<BluetoothDevice> _pairedDevices = [];
  bool _isDrivingForward = false;
  bool _isDrivingBackward = false;
  String _status = 'Nicht verbunden';
  final List<String> _logLines = [];
  bool _isDisposed = false;

  ControlMode _controlMode = ControlMode.throttleWheel;
  AppScreen _activeScreen = AppScreen.home;

  // UI settings (mirrors screenshots)
  double _sensitivity = 0.5; // 0..1
  bool _vibrationEnabled = true;
  bool _soundEnabled = true;
  bool _autoCenteringEnabled = true;

  Timer? _gyroPollTimer;
  Timer? _keepAliveTimer;
  Timer? _controlUpdateTimer;
  DateTime? _lastSentTime;
  StreamSubscription<AccelerometerEvent>? _accelSub;
  Timer? _reconnectTimer;

  // Steering state (-1..1 normalized)
  double _steerFactor = 0;
  // Throttle state (-1..1: reverse..forward)
  double _throttleFactor = 0;

  // For a more realistic steering wheel UI.
  double _steeringWheelRotation = 0;
  double? _lastWheelDragAngle;

  String? _lastSentControlCommand;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureBluetoothEnabledAndRefresh();
    });
  }

  Future<void> _ensureBluetoothEnabledAndRefresh() async {
    final enabled = await FlutterBluetoothSerial.instance.isEnabled;
    if (enabled != true) {
      await FlutterBluetoothSerial.instance.requestEnable();
    }

    final granted = await _requestBluetoothPermissions();
    if (!granted) {
      if (mounted && !_isDisposed) {
        setState(() {
          _status = 'Bluetooth-Berechtigung benötigt';
        });
      }
      return;
    }

    await _refreshPairedDevices();
  }

  Future<bool> _requestBluetoothPermissions() async {
    // Android 12+ requires runtime permissions for classic Bluetooth.
    final statuses = await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();

    // Accept if at least bluetooth connect is granted.
    return statuses[Permission.bluetoothConnect]?.isGranted == true ||
        statuses[Permission.bluetooth]?.isGranted == true;
  }

  @override
  void dispose() {
    _isDisposed = true;
    _gyroPollTimer?.cancel();
    _keepAliveTimer?.cancel();
    _controlUpdateTimer?.cancel();
    _reconnectTimer?.cancel();
    _accelSub?.cancel();
    // Close connection without triggering setState during dispose.
    _connection?.close();
    _connection = null;
    _logController.dispose();
    super.dispose();
  }

  Future<void> _refreshPairedDevices() async {
    final devices = await FlutterBluetoothSerial.instance.getBondedDevices();
    if (mounted && !_isDisposed) {
      setState(() {
        _pairedDevices = devices;
      });
    }
  }


  Future<void> _connectToDevice(BluetoothDevice device) async {
    setState(() {
      _status = 'Verbinde mit ${device.name}...';
    });

    try {
      final connection = await BluetoothConnection.toAddress(device.address);
      setState(() {
        _connection = connection;
        _selectedDevice = device;
        _status = 'Verbunden mit ${device.name}';
        _lastSentControlCommand = null;
      });

      // Keep the SPP connection alive by sending periodic control updates.
      _keepAliveTimer?.cancel();
      _keepAliveTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (_connection == null) return;
        final last = _lastSentTime ?? DateTime.fromMillisecondsSinceEpoch(0);
        if (DateTime.now().difference(last) >
            const Duration(milliseconds: 400)) {
          _sendKeepAlive();
        }
      });

      _startControlUpdateTimer();
      _sendControlState(logCommand: true);

      connection.input?.listen(
        (data) {
          // Log incoming data so we can see whether the ESP32 receives anything.
          final text = utf8.decode(data, allowMalformed: true);
          _log('RX: $text');
        },
        onDone: () {
          _log('Verbindung getrennt');
          _disconnect();
          _scheduleReconnect();
        },
      );
    } catch (e) {
      _log('Fehler beim Verbinden: $e');
      if (mounted && !_isDisposed) {
        setState(() {
          _status = 'Verbindung fehlgeschlagen';
        });
      }
    } finally {
      // Ensure status is updated even if connection fails.
      if (mounted && !_isDisposed) {
        setState(() {
          if (_connection == null) {
            _status = 'Nicht verbunden';
          }
        });
      }
    }
  }

  Future<void> _disconnect() async {
    _gyroPollTimer?.cancel();
    _keepAliveTimer?.cancel();
    _stopControlUpdateTimer();
    _accelSub?.cancel();

    if (_connection != null) {
      await _connection!.close();
      _connection = null;
    }

    if (!mounted || _isDisposed) {
      return;
    }

    setState(() {
      _selectedDevice = null;
      _status = 'Nicht verbunden';
      _isDrivingForward = false;
      _isDrivingBackward = false;
      _steerFactor = 0;
    });
  }

  void _sendKeepAlive() {
    if (_connection == null) return;
    try {
      // Send a single zero byte to keep the connection alive.
      _connection!.output.add(Uint8List.fromList([0]));
      _lastSentTime = DateTime.now();
      _log('-> (keepalive)');
    } catch (e) {
      _log('Keepalive-Fehler: $e');
    }
  }

  String _buildControlCommand() {
    // Apply sensitivity to steering and throttle.
    final steerFactor = (_steerFactor * _sensitivity).clamp(-1.0, 1.0);
    final throttleFactor = (_throttleFactor * _sensitivity).clamp(-1.0, 1.0);

    // Steering is mapped 0..100 (50 = centered)
    final steer = ((steerFactor * 50) + 50).round();
    // Throttle is mapped -100..100 (negative = reverse)
    final speed = (throttleFactor * 100).round();
    return 'S${steer}V$speed\n';
  }

  void _sendControlState({bool logCommand = false}) {
    if (_connection == null) return;

    final command = _buildControlCommand();
    if (command == _lastSentControlCommand) return;
    _lastSentControlCommand = command;

    try {
      _connection!.output.add(Uint8List.fromList(command.codeUnits));
      _lastSentTime = DateTime.now();
      if (logCommand) _log('-> $command');
    } catch (e) {
      _log('Sende-Fehler: $e');
    }
  }

  void _provideFeedback({bool sound = true, bool vibration = true}) {
    if (_vibrationEnabled && vibration) {
      HapticFeedback.lightImpact();
    }
    if (_soundEnabled && sound) {
      SystemSound.play(SystemSoundType.click);
    }
  }

  void _startControlUpdateTimer() {
    _controlUpdateTimer?.cancel();
    _controlUpdateTimer = Timer.periodic(const Duration(milliseconds: 150), (
      _,
    ) {
      _sendControlState();
    });
  }

  void _stopControlUpdateTimer() {
    _controlUpdateTimer?.cancel();
    _controlUpdateTimer = null;
    _lastSentControlCommand = null;
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    if (_selectedDevice == null) return;

    _reconnectTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted || _isDisposed) return;
      if (_connection != null) return;
      if (_selectedDevice == null) return;

      _log('Verbindung getrennt – versuche erneut zu verbinden...');
      _connectToDevice(_selectedDevice!);
    });
  }

  void _log(String message) {
    if (!mounted || _isDisposed) return;
    setState(() {
      _status = message;
      _logLines.add(
        '${DateTime.now().toIso8601String().substring(11, 19)}: $message',
      );
      if (_logLines.length > 5) {
        _logLines.removeAt(0);
      }
    });
  }

  void _setControlMode(ControlMode mode) {
    if (!mounted || _isDisposed) return;
    if (mode == _controlMode) return;

    setState(() {
      _controlMode = mode;
      _steerFactor = 0;
    });

    _provideFeedback();
    _accelSub?.cancel();

    if (mode == ControlMode.gyro) {
      // Only enable gyro mode on mobile platforms (Android/iOS).
      final isMobile =
          defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS;
      if (kIsWeb || !isMobile) {
        _log('Gyroskopmodus nicht verfügbar auf dieser Plattform');
        _setControlMode(ControlMode.throttleWheel);
        return;
      }

      // Use the accelerometer to derive a left/right tilt (roll).
      // In landscape mode, the device's y/z axes map to left-right tilt.
      try {
        final stream = accelerometerEvents;
        _accelSub = stream.listen(
          (event) {
            try {
              final roll = atan2(event.y, event.z);
              final steer = (roll / (pi / 2)).clamp(-1.0, 1.0);

              // smooth out jitter
              if (!mounted || _isDisposed) return;
              setState(() {
                _steerFactor = (_steerFactor * 0.85) + (steer * 0.15);
                _steeringWheelRotation =
                    asin(_steerFactor.clamp(-1.0, 1.0));
              });
              _sendControlState();
            } catch (e) {
              _log('Gyro-Stream-Fehler: $e');
            }
          },
          onError: (error, stackTrace) {
            _log('Gyroskop-Fehler: $error');
            if (error is MissingPluginException) {
              _setControlMode(ControlMode.throttleWheel);
            }
          },
          cancelOnError: false,
        );
      } on MissingPluginException catch (e) {
        _log('Gyroskop nicht verfügbar: ${e.message}');
        if (mounted && !_isDisposed) {
          setState(() {
            _controlMode = ControlMode.throttleWheel;
          });
        }
        return;
      } catch (e) {
        _log('Gyroskopfehler: $e');
      }
    }
  }

  void _setDriveState({required bool forward, required bool backward}) {
    _provideFeedback();

    setState(() {
      _isDrivingForward = forward;
      _isDrivingBackward = backward;
      _throttleFactor = forward
          ? 1.0
          : backward
          ? -1.0
          : 0.0;
    });

    _sendControlState();
  }

  void _onSteeringWheelDrag(Offset localPosition, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final offset = localPosition - center;
    final angle = atan2(offset.dy, offset.dx);

    _lastWheelDragAngle ??= angle;

    var delta = angle - _lastWheelDragAngle!;
    // Normalize delta to [-pi, pi] to avoid jumps when crossing the -pi/pi boundary
    while (delta > pi) {
      delta -= 2 * pi;
    }
    while (delta < -pi) {
      delta += 2 * pi;
    }

    _lastWheelDragAngle = angle;

    setState(() {
      _steeringWheelRotation += delta;
      // Use sine so full rotation maps to steering range -1..1.
      _steerFactor = sin(_steeringWheelRotation).clamp(-1.0, 1.0);
    });

    _sendControlState();
  }

  void _resetSteeringWheel() {
    if (!_autoCenteringEnabled) return;

    setState(() {
      _steerFactor = 0;
      _steeringWheelRotation = 0;
      _lastWheelDragAngle = null;
    });
    _sendControlState();
  }

  // Kein eigener Verbindungsbereich mehr: alles wird über das Menü gesteuert.
  String get _controlModeLabel {
    switch (_controlMode) {
      case ControlMode.arrows:
        return 'Pfeilsteuerung';
      case ControlMode.throttleWheel:
        return 'Gas + Lenkrad';
      case ControlMode.gyro:
        return 'Gyroskop';
    }
  }

  Widget _buildDriveControls() {
    switch (_controlMode) {
      case ControlMode.arrows:
        return _buildArrowControls();
      case ControlMode.throttleWheel:
        return _buildThrottleWheelControls();
      case ControlMode.gyro:
        return _buildGyroControls();
    }
  }

  Widget _buildArrowControls() {
    return Row(
      children: [
        Expanded(
          child: Column(
            children: [
              ElevatedButton.icon(
                onPressed: _connection != null
                    ? () => _setDriveState(forward: true, backward: false)
                    : null,
                icon: const Icon(Icons.arrow_upward),
                label: const Text('Vorwärts'),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(60),
                ),
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: _connection != null
                    ? () => _setDriveState(forward: false, backward: true)
                    : null,
                icon: const Icon(Icons.arrow_downward),
                label: const Text('Rückwärts'),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(60),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            children: [
              ElevatedButton.icon(
                onPressed: _connection != null
                    ? () {
                        setState(() {
                          _steerFactor = -1.0;
                          _steeringWheelRotation = -pi / 2;
                        });
                        _sendControlState();
                      }
                    : null,
                icon: const Icon(Icons.arrow_back),
                label: const Text('Links'),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(60),
                ),
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: _connection != null
                    ? () {
                        setState(() {
                          _steerFactor = 1.0;
                          _steeringWheelRotation = pi / 2;
                        });
                        _sendControlState();
                      }
                    : null,
                icon: const Icon(Icons.arrow_forward),
                label: const Text('Rechts'),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(60),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildThrottleWheelControls() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: GestureDetector(
                onTapDown: _connection != null
                    ? (_) => _setDriveState(forward: true, backward: false)
                    : null,
                onTapUp: _connection != null
                    ? (_) => _setDriveState(forward: false, backward: false)
                    : null,
                onTapCancel: _connection != null
                    ? () => _setDriveState(forward: false, backward: false)
                    : null,
                child: ElevatedButton(
                  onPressed: null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isDrivingForward ? Colors.green : null,
                    minimumSize: const Size(0, 44),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  child: const Text('Gas (Vorwärts)'),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: GestureDetector(
                onTapDown: _connection != null
                    ? (_) => _setDriveState(forward: false, backward: true)
                    : null,
                onTapUp: _connection != null
                    ? (_) => _setDriveState(forward: false, backward: false)
                    : null,
                onTapCancel: _connection != null
                    ? () => _setDriveState(forward: false, backward: false)
                    : null,
                child: ElevatedButton(
                  onPressed: null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isDrivingBackward ? Colors.orange : null,
                    minimumSize: const Size(0, 44),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  child: const Text('Bremse / Rückwärts'),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white24),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Steuerung',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 10),
                    Text('Modus: $_controlModeLabel'),
                    const SizedBox(height: 6),
                    Text(
                      'Lenkfaktor: ${(_steerFactor * 100).toStringAsFixed(0)}%',
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Nutze das Lenkrad, um nach links/rechts zu steuern.',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                // Keep the wheel responsive on narrow/tall screens.
                final available = min(
                  constraints.maxWidth,
                  constraints.maxHeight,
                );
                final wheelSize = min(180.0, available);

                return SizedBox(
                  width: wheelSize,
                  height: wheelSize,
                  child: GestureDetector(
                    onPanUpdate: (details) {
                      final local = details.localPosition;
                      _onSteeringWheelDrag(local, Size(wheelSize, wheelSize));
                    },
                    onPanEnd: (_) {
                      _resetSteeringWheel();
                    },
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white24, width: 3),
                      ),
                      child: Center(
                        child: Transform.rotate(
                          angle: _steeringWheelRotation,
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: Colors.white24,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.navigation,
                              color: Colors.white,
                              size: 24,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white24),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Geschwindigkeit',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text('Wert: ${(_throttleFactor * 100).toStringAsFixed(0)}%'),
              Slider(
                value: _throttleFactor,
                min: -1.0,
                max: 1.0,
                divisions: 40,
                label: '${(_throttleFactor * 100).toStringAsFixed(0)}%',
                onChanged: _connection != null
                    ? (value) {
                        setState(() {
                          _throttleFactor = value;
                          _isDrivingForward = value > 0;
                          _isDrivingBackward = value < 0;
                        });
                        _sendControlState();
                      }
                    : null,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildGyroControls() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: GestureDetector(
                onTapDown: _connection != null
                    ? (_) => _setDriveState(forward: true, backward: false)
                    : null,
                onTapUp: _connection != null
                    ? (_) => _setDriveState(forward: false, backward: false)
                    : null,
                onTapCancel: _connection != null
                    ? () => _setDriveState(forward: false, backward: false)
                    : null,
                child: ElevatedButton(
                  onPressed: null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isDrivingForward ? Colors.green : null,
                    minimumSize: const Size(0, 44),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  child: const Text('Gas (Vorwärts)'),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: GestureDetector(
                onTapDown: _connection != null
                    ? (_) => _setDriveState(forward: false, backward: true)
                    : null,
                onTapUp: _connection != null
                    ? (_) => _setDriveState(forward: false, backward: false)
                    : null,
                onTapCancel: _connection != null
                    ? () => _setDriveState(forward: false, backward: false)
                    : null,
                child: ElevatedButton(
                  onPressed: null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isDrivingBackward ? Colors.orange : null,
                    minimumSize: const Size(0, 44),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  child: const Text('Bremse / Rückwärts'),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white24),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Gyroskopsteuerung',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              Text('Neige das Telefon nach links/rechts, um zu lenken.'),
              const SizedBox(height: 6),
              Text('Lenkfaktor: ${(_steerFactor * 100).toStringAsFixed(0)}%'),
              const SizedBox(height: 12),
              const Text(
                'Geschwindigkeit',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text('Wert: ${(_throttleFactor * 100).toStringAsFixed(0)}%'),
              Slider(
                value: _throttleFactor,
                min: -1.0,
                max: 1.0,
                divisions: 40,
                label: '${(_throttleFactor * 100).toStringAsFixed(0)}%',
                onChanged: _connection != null
                    ? (value) {
                        setState(() {
                          _throttleFactor = value;
                          _isDrivingForward = value > 0;
                          _isDrivingBackward = value < 0;
                        });
                        _sendControlState();
                      }
                    : null,
              ),
            ],
          ),
        ),
      ],
    );
  }

  // Home screen replicates the layout shown in the provided UI screenshots.
  Widget _buildHomeScreen() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth > 900;
        return Padding(
          padding: const EdgeInsets.all(16),
          child: isWide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _buildBluetoothPanel()),
                    const SizedBox(width: 16),
                    Expanded(child: _buildHomeRightPanel()),
                  ],
                )
              : ListView(
                  padding: const EdgeInsets.only(top: 0),
                  children: [
                    _buildBluetoothPanel(),
                    const SizedBox(height: 16),
                    _buildHomeRightPanel(),
                  ],
                ),
        );
      },
    );
  }

  Widget _buildBluetoothPanel() {
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF0A2F2F), Color(0xFF003333)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white12),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Bluetooth',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text('Verfügbare Geräte:'),
          const SizedBox(height: 12),
          _pairedDevices.isEmpty
              ? const Center(
                  child: Text(
                    'Keine gekoppelten Geräte gefunden.',
                    style: TextStyle(color: Colors.white60),
                  ),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _pairedDevices.length,
                  itemBuilder: (context, index) {
                    final device = _pairedDevices[index];
                    final selected = _selectedDevice?.address == device.address;
                    final connected = _connection != null && selected;
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 0),
                      title: Text(device.name ?? device.address),
                      subtitle: Text(device.address),
                      trailing: Text(
                        connected ? 'Verbunden' : 'Wählen',
                        style: TextStyle(
                          color: connected ? Colors.greenAccent : Colors.white70,
                        ),
                      ),
                      selected: selected,
                      selectedTileColor: Colors.white10,
                      onTap: () {
                        setState(() {
                          _selectedDevice = device;
                        });
                      },
                      onLongPress: () {
                        _connectToDevice(device);
                      },
                    );
                  },
                ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: _refreshPairedDevices,
                  child: const Text('Aktualisieren'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: _selectedDevice == null
                      ? null
                      : () {
                          if (_connection != null) {
                            _disconnect();
                          } else {
                            _connectToDevice(_selectedDevice!);
                          }
                        },
                  child: Text(_connection != null ? 'Trennen' : 'Verbinden'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text('Status: $_status'),
        ],
      ),
    );
  }

  Widget _buildHomeRightPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: const LinearGradient(
              colors: [Color(0xFF0B3A2C), Color(0xFF00463B)],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
            border: Border.all(color: Colors.white12),
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Steuerung',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              const Text('Starte die Robotersteuerung'),
              const SizedBox(height: 12),
              Center(
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Start'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      vertical: 14,
                      horizontal: 24,
                    ),
                  ),
                  onPressed: () {
                    setState(() {
                      _activeScreen = AppScreen.modeSelection;
                    });
                  },
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: GestureDetector(
                onTap: () {
                  setState(() {
                    _activeScreen = AppScreen.modeSelection;
                  });
                },
                child: _buildInfoCard(
                  title: '3 Steuerungsmodi',
                  subtitle: 'Lenkrad, Button, Gyro',
                  icon: Icons.settings_input_component,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: GestureDetector(
                onTap: () {
                  setState(() {
                    _activeScreen = AppScreen.settings;
                  });
                },
                child: _buildInfoCard(
                  title: 'Einstellungen',
                  subtitle: 'Anpassen & Features',
                  icon: Icons.settings,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildInfoCard({
    required String title,
    required String subtitle,
    required IconData icon,
  }) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          colors: [Color(0xFF0C3F2D), Color(0xFF005141)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: Colors.white12),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 28, color: Colors.greenAccent),
          const SizedBox(height: 12),
          Text(
            title,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),
          Text(subtitle),
        ],
      ),
    );
  }

  Widget _buildModeSelectionScreen() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Steuerungsmodus wählen',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          const Text('Wähle deinen bevorzugten Steuerungsmodus'),
          const SizedBox(height: 16),
          Flexible(
            fit: FlexFit.loose,
            child: GridView.count(
              crossAxisCount: MediaQuery.of(context).size.width > 800 ? 3 : 1,
              crossAxisSpacing: 16,
              mainAxisSpacing: 16,
              childAspectRatio: 1.3,
              children: [
                _buildModeCard(
                  title: 'Lenkrad & Pedale',
                  subtitle: 'Klassische Steuerung mit Lenkrad, Gas und Bremse',
                  icon: Icons.sports_motorsports,
                  onTap: () {
                    _setControlMode(ControlMode.throttleWheel);
                    setState(() => _activeScreen = AppScreen.drive);
                  },
                  selected: _controlMode == ControlMode.throttleWheel,
                ),
                _buildModeCard(
                  title: 'Button Steuerung',
                  subtitle: 'Steuerung mit Richtungstasten (Vor, Zurück, Links, Rechts)',
                  icon: Icons.gamepad,
                  onTap: () {
                    _setControlMode(ControlMode.arrows);
                    setState(() => _activeScreen = AppScreen.drive);
                  },
                  selected: _controlMode == ControlMode.arrows,
                ),
                _buildModeCard(
                  title: 'Gyro Steuerung',
                  subtitle: 'Lenken durch Neigen des Handys + Gas/Bremse',
                  icon: Icons.phone_android,
                  onTap: () {
                    _setControlMode(ControlMode.gyro);
                    setState(() => _activeScreen = AppScreen.drive);
                  },
                  selected: _controlMode == ControlMode.gyro,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModeCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required VoidCallback onTap,
    bool selected = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? Colors.greenAccent : Colors.white12,
            width: selected ? 2 : 1,
          ),
          gradient: const LinearGradient(
            colors: [Color(0xFF0C3F2D), Color(0xFF005141)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 28, color: Colors.greenAccent),
            const SizedBox(height: 14),
            Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text(subtitle),
          ],
        ),
      ),
    );
  }

  Widget _buildDriveScreen() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Steuerung: $_controlModeLabel',
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.home),
                onPressed: () {
                  setState(() {
                    _activeScreen = AppScreen.home;
                  });
                },
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: _buildSpeedDisplay()),
              const SizedBox(width: 16),
              Expanded(child: _buildDriveControls()),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _buildConnectionStatusCard()),
              const SizedBox(width: 12),
              Expanded(child: _buildSettingsSummaryCard()),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSpeedDisplay() {
    final speedPercent = (_throttleFactor * 100).round();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          colors: [Color(0xFF0B3A2C), Color(0xFF00463B)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            '${speedPercent.abs()} km/h',
            style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            speedPercent == 0
                ? 'Stillstand'
                : speedPercent > 0
                    ? 'Vorwärts'
                    : 'Rückwärts',
            style: const TextStyle(fontSize: 16),
          ),
          const SizedBox(height: 12),
          LinearProgressIndicator(
            value: (speedPercent.abs() / 100).clamp(0.0, 1.0),
            backgroundColor: Colors.white12,
            color: Colors.greenAccent,
            minHeight: 8,
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionStatusCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          colors: [Color(0xFF0A2F2F), Color(0xFF003333)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Verbindung',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text('Gerät: ${_selectedDevice?.name ?? 'Kein Gerät'}'),
          const SizedBox(height: 4),
          Text('Status: ${_connection != null ? 'Verbunden' : 'Nicht verbunden'}'),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: _pairedDevices.isEmpty ? null : _refreshPairedDevices,
                  child: const Text('Aktualisieren'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton(
                  onPressed: _selectedDevice == null
                      ? null
                      : () {
                          if (_connection != null) {
                            _disconnect();
                          } else {
                            _connectToDevice(_selectedDevice!);
                          }
                        },
                  child: Text(_connection != null ? 'Trennen' : 'Verbinden'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsSummaryCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          colors: [Color(0xFF0A2F2F), Color(0xFF003333)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Einstellungen',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text('Sensitivität: ${( _sensitivity * 100).round()}%'),
          Text('Vibration: ${_vibrationEnabled ? 'An' : 'Aus'}'),
          Text('Sound: ${_soundEnabled ? 'An' : 'Aus'}'),
          const SizedBox(height: 8),
          ElevatedButton(
            onPressed: () {
              setState(() {
                _activeScreen = AppScreen.settings;
              });
            },
            child: const Text('Bearbeiten'),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsScreen() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Einstellungen',
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.home),
                onPressed: () {
                  setState(() {
                    _activeScreen = AppScreen.home;
                  });
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              gradient: const LinearGradient(
                colors: [Color(0xFF0B3A2C), Color(0xFF00463B)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              border: Border.all(color: Colors.white12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Steuerungsempfindlichkeit',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Slider(
                  value: _sensitivity,
                  min: 0,
                  max: 1,
                  divisions: 4,
                  label: '${(_sensitivity * 100).round()}%',
                  onChanged: (value) {
                    setState(() {
                      _sensitivity = value;
                    });
                  },
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: const [
                    Text('Niedrig'),
                    Text('Mittel'),
                    Text('Hoch'),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _buildToggleSetting(
            label: 'Vibration',
            icon: Icons.vibration,
            value: _vibrationEnabled,
            onChanged: (v) => setState(() => _vibrationEnabled = v),
          ),
          _buildToggleSetting(
            label: 'Sound',
            icon: Icons.volume_up,
            value: _soundEnabled,
            onChanged: (v) => setState(() => _soundEnabled = v),
          ),
          _buildToggleSetting(
            label: 'Auto-Zentrierung',
            icon: Icons.center_focus_strong,
            value: _autoCenteringEnabled,
            onChanged: (v) => setState(() => _autoCenteringEnabled = v),
          ),
        ],
      ),
    );
  }

  Widget _buildToggleSetting({
    required String label,
    required IconData icon,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Card(
      margin: const EdgeInsets.only(top: 12),
      color: const Color(0x59000000),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: SwitchListTile.adaptive(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        secondary: Icon(icon, color: Colors.greenAccent),
        title: Text(label, style: const TextStyle(fontSize: 16)),
        value: value,
        onChanged: onChanged,
        activeThumbColor: Colors.greenAccent,
        activeTrackColor: const Color(0x6600FF00),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.black87,
        elevation: 0,
        centerTitle: true,
        title: Text(_activeScreen == AppScreen.home
            ? 'RoboControl'
            : _activeScreen == AppScreen.modeSelection
                ? 'Steuerungsmodus wählen'
                : _activeScreen == AppScreen.drive
                    ? 'Steuerung'
                    : 'Einstellungen'),
      ),
      backgroundColor: Colors.black,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF000000), Color(0xFF061414)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: _activeScreen == AppScreen.home
              ? _buildHomeScreen()
              : _activeScreen == AppScreen.modeSelection
                  ? _buildModeSelectionScreen()
                  : _activeScreen == AppScreen.drive
                      ? _buildDriveScreen()
                      : _buildSettingsScreen(),
        ),
      ),
    );
  }
}

