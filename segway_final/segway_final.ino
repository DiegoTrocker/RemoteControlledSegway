#include <Wire.h>
#include <Arduino.h>
#include "BluetoothSerial.h"
#include "esp_system.h"
#include "esp_mac.h"
#include "esp_err.h"

#define MPU_ADDR 0x68

// PWM channels (ESP32 supports 16 channels: 0..15)
const int MOTOR_CH_R1 = 0;
const int MOTOR_CH_L1 = 1;
const int MOTOR_CH_R2 = 2;
const int MOTOR_CH_L2 = 3;

BluetoothSerial SerialBT;
bool btConnected = false;

// Timeout to stop the motors in case we stop receiving commands.
const unsigned long COMMAND_TIMEOUT_MS = 2000;
unsigned long lastCommandMillis = 0;
bool commandTimeoutActive = false;

// Incoming Bluetooth command buffer (avoid dynamic Strings to reduce heap fragmentation)
char btReceived[65];
size_t btReceivedLen = 0;

// ---------------- Motor pins ----------------
const int RPWM1 = 25;
const int LPWM1 = 26;
const int RPWM2 = 27;
const int LPWM2 = 14;

// ---------------- IMU values ----------------
float pitch = 0.0;
float pitchOffset = 0.0;
float gyroYoffset = 0.0;
unsigned long lastMicros = 0;

// ---------------- Control ----------------
float targetAngle = 0.0;
int turnPWM = 0;

// Control values from the app
int turnValue = 50;  // 0..100 (50 = centered)
int speedValue = 0;  // -100..100 (negative = reverse)

// Tune these
float Kp = 14.0;            // proportional gain (tilt correction)
float Kd = 0.8;             // derivative gain (damping / dampen gyro response)
float gyroSensitivity = 0.6; // scale how strongly the gyro rate affects correction (0..1)

// Motor behavior
int minPWM = 70;       // minimum usable PWM to overcome motor deadzone
int maxPWM = 255;
float deadband = 0.2;  // small deadband to ignore tiny noise around zero

// Debug timing
unsigned long lastPrint = 0;

// ---------- MPU helpers ----------
void mpuWrite(byte reg, byte value) {
  Wire.beginTransmission(MPU_ADDR);
  Wire.write(reg);
  Wire.write(value);
  Wire.endTransmission();
  
}

bool mpuRead(byte startReg, byte *buffer, int len) {
  Wire.beginTransmission(MPU_ADDR);
  Wire.write(startReg);
  if (Wire.endTransmission(false) != 0) return false;

  int count = Wire.requestFrom(MPU_ADDR, len);
  if (count != len) return false;

  for (int i = 0; i < len; i++) {
    buffer[i] = Wire.read();
  }
  return true;
}

void setupMPU() {
  mpuWrite(0x6B, 0x00);  // wake up
  mpuWrite(0x1C, 0x00);  // accel ±2g
  mpuWrite(0x1B, 0x00);  // gyro ±250 dps
}

bool readMPU(float &accAngle, float &gyroRate) {
  byte data[14];

  if (!mpuRead(0x3B, data, 14)) return false;

  int16_t axRaw = (data[0] << 8) | data[1];
  int16_t ayRaw = (data[2] << 8) | data[3];
  int16_t azRaw = (data[4] << 8) | data[5];

  int16_t gxRaw = (data[8] << 8) | data[9];
  int16_t gyRaw = (data[10] << 8) | data[11];
  int16_t gzRaw = (data[12] << 8) | data[13];

  float ax = axRaw / 16384.0;
  float ay = ayRaw / 16384.0;
  float az = azRaw / 16384.0;

  // choose one tilt axis
  accAngle = atan2(ax, az) * 180.0 / PI;

  // gyro Y axis in deg/s
  gyroRate = (gyRaw / 131.0) - gyroYoffset;

  return true;
}

// ---------- Motor helpers ----------
void stopMotors() {
  ledcWrite(MOTOR_CH_R1, 0);
  ledcWrite(MOTOR_CH_L1, 0);
  ledcWrite(MOTOR_CH_R2, 0);
  ledcWrite(MOTOR_CH_L2, 0);
}

static void applyMotor(int pwm, int chForward, int chReverse) {
  pwm = constrain(pwm, -maxPWM, maxPWM);

  if (pwm > 0) {
    ledcWrite(chForward, pwm);
    ledcWrite(chReverse, 0);
  } else if (pwm < 0) {
    ledcWrite(chForward, 0);
    ledcWrite(chReverse, -pwm);
  } else {
    ledcWrite(chForward, 0);
    ledcWrite(chReverse, 0);
  }
}

void setMotors(int pwmLeft, int pwmRight) {
  pwmLeft = constrain(pwmLeft, -maxPWM, maxPWM);
  pwmRight = constrain(pwmRight, -maxPWM, maxPWM);

  applyMotor(pwmLeft, MOTOR_CH_R1, MOTOR_CH_L1);
  applyMotor(pwmRight, MOTOR_CH_R2, MOTOR_CH_L2);
}

void setMotorPair(int pwm) {
  setMotors(pwm, pwm);
}

// ---------- Calibration ----------
bool calibrateMPU() {
  float accSum = 0.0;
  float gyroSum = 0.0;
  int good = 0;

  for (int i = 0; i < 300; i++) {
    byte data[14];
    if (mpuRead(0x3B, data, 14)) {
      int16_t axRaw = (data[0] << 8) | data[1];
      int16_t azRaw = (data[4] << 8) | data[5];
      int16_t gyRaw = (data[10] << 8) | data[11];

      float ax = axRaw / 16384.0;
      float az = azRaw / 16384.0;
      float accAngle = atan2(ax, az) * 180.0 / PI;
      float gyroRate = gyRaw / 131.0;

      accSum += accAngle;
      gyroSum += gyroRate;
      good++;
    }
    delay(5);
  }

  if (good == 0) return false;

  pitchOffset = accSum / good;
  gyroYoffset = gyroSum / good;
  return true;
}

void setup() {
  Serial.begin(115200);
    while (!Serial) {
    delay(10);
  }

  Serial.println("Starte ESP32 Bluetooth und zeige MAC-Adresse an...");

  if (!SerialBT.begin("ESP32_BT")) {
    Serial.println("Fehler: Bluetooth konnte nicht gestartet werden.");
    while (true) {
      delay(1000);
    }
  }

  // ESP32 Bluetooth MAC-Adresse auslesen
  uint8_t btMac[6];
  esp_err_t res = esp_read_mac(btMac, ESP_MAC_BT);
  if (res != ESP_OK) {
    Serial.print("Fehler beim Auslesen der MAC-Adresse: ");
    Serial.println(esp_err_to_name(res));
  } else {
    // MAC-Adresse als lesbaren String ausgeben (z.B. 30:AE:A4:C1:23:45)
    char macStr[18];
    snprintf(macStr, sizeof(macStr), "%02X:%02X:%02X:%02X:%02X:%02X",
             btMac[0], btMac[1], btMac[2], btMac[3], btMac[4], btMac[5]);
    Serial.print("Bluetooth MAC: ");
    Serial.println(macStr);
  }
  delay(500);

  Wire.begin(21, 22);
  Wire.setClock(400000);

  const int pwmFreq = 2000;
  const int pwmResolution = 8;
  ledcSetup(MOTOR_CH_R1, pwmFreq, pwmResolution);
  ledcAttachPin(RPWM1, MOTOR_CH_R1);
  ledcSetup(MOTOR_CH_L1, pwmFreq, pwmResolution);
  ledcAttachPin(LPWM1, MOTOR_CH_L1);
  ledcSetup(MOTOR_CH_R2, pwmFreq, pwmResolution);
  ledcAttachPin(RPWM2, MOTOR_CH_R2);
  ledcSetup(MOTOR_CH_L2, pwmFreq, pwmResolution);
  ledcAttachPin(LPWM2, MOTOR_CH_L2);

  stopMotors();

  setupMPU();

  Serial.println("Keep robot upright and still for calibration...");
  delay(2000);

  if (!calibrateMPU()) {
    Serial.println("MPU not detected / read failed");
    while (true) {
      stopMotors();
      delay(1000);
    }
  }

  // After subtracting offset, upright should be near 0
  pitch = 0.0;
  lastMicros = micros();

  Serial.print("Pitch offset: ");
  Serial.println(pitchOffset);
  Serial.print("Gyro offset: ");
  Serial.println(gyroYoffset);
}

void resetCommandTimeout() {
  lastCommandMillis = millis();
  commandTimeoutActive = false;
}

void handleBluetooth() {
  if (!SerialBT.connected()) return;

  while (SerialBT.available()) {
    char c = SerialBT.read();
    if (c == '\r') continue;

    // Legacy single-key commands (immediate response)
    bool gotCommand = true;
    switch (c) {
      case 'w':
      case 'W':
        speedValue = 100;
        break;

      case 's':
      case 'S':
        speedValue = -100;
        break;

      case 'x':
      case 'X':
        speedValue = 0;
        break;

      case 'a':
      case 'A':
        turnValue = 0;
        break;

      case 'd':
      case 'D':
        turnValue = 100;
        break;

      case 'q':
      case 'Q':
        turnValue = 50;
        break;

      default:
        gotCommand = false;
        break;
    }

    if (gotCommand) {
      resetCommandTimeout();
      continue;
    }

    // New format: S<0-100>V<-100..100> (example: S50V80)
    if (c == '\n') {
      btReceived[btReceivedLen] = '\0';
      btReceivedLen = 0;

      // copy into a temporary buffer and normalize to uppercase
      char cmd[65] = "";
      for (size_t i = 0; i < sizeof(cmd) - 1 && btReceived[i] != '\0'; ++i) {
        cmd[i] = toupper((unsigned char)btReceived[i]);
        cmd[i + 1] = '\0';
      }

      int steer = -1;
      int speed = 0;
      if (sscanf(cmd, "S%dV%d", &steer, &speed) == 2) {
        if (steer >= 0 && steer <= 100) {
          turnValue = steer;
        }
        if (speed >= -100 && speed <= 100) {
          speedValue = speed;
        }
      }

      resetCommandTimeout();
      continue;
    }

    // Accumulate non-button data for multi-byte commands.
    if (btReceivedLen < sizeof(btReceived) - 1) {
      btReceived[btReceivedLen++] = c;
    } else {
      // Buffer overflow - reset to recover
      btReceivedLen = 0;
    }
  }
}

void loop() {
  // Bluetooth connection monitoring
  if (SerialBT.connected()) {
    if (!btConnected) {
      btConnected = true;
      Serial.println("Bluetooth verbunden");
    }
  } else {
    if (btConnected) {
      btConnected = false;
      Serial.println("Bluetooth getrennt - stoppe Motoren");
      targetAngle = 0;
      turnPWM = 0;
      speedValue = 0;
      btReceivedLen = 0;
      commandTimeoutActive = false;
      stopMotors();
    }
  }

  float accAngle, gyroRate;

  handleBluetooth();

  // Map received control values into the balancing controller.
  // Steering: 0..100 where 50 means no turn.
  const int maxTurnPWM = 80;
  turnPWM = map(turnValue, 0, 100, maxTurnPWM, -maxTurnPWM);
  if (abs(turnPWM) < 5) turnPWM = 0;

  // Speed: -100..100 mapped to a target lean angle.
  const float maxTargetAngle = 10.0f;
  targetAngle = (speedValue / 100.0f) * maxTargetAngle;
  if (abs(speedValue) < 10) {
    targetAngle = 0;
  }

  if (!readMPU(accAngle, gyroRate)) {
    Serial.println("MPU read failed");
    stopMotors();
    delay(20);
    return;
  }

  unsigned long now = micros();
  float dt = (now - lastMicros) / 1000000.0f;
  lastMicros = now;

  if (dt <= 0.0f || dt > 0.05f) dt = 0.01f;

  // complementary filter
  float accCorrected = accAngle - pitchOffset;
  pitch = 0.98 * (pitch + gyroRate * dt) + 0.02 * accCorrected;

  // PD control
  float error = targetAngle - pitch;
  float output = Kp * error - Kd * gyroRate * gyroSensitivity;

  // safety cutoff
  if (abs(pitch) > 30) {
    stopMotors();
    Serial.println("Too much tilt - stopped");
    delay(50);
    return;
  }

  // Convert control output to PWM
  int pwm = (int)output;

  // Tiny deadband only for very small noise near zero
  if (abs(error) < deadband && abs(gyroRate) < 1.0f) {
    pwm = 0;
  } else {
    // Add minimum PWM smoothly to overcome motor deadzone
    if (pwm > 0) pwm += minPWM;
    if (pwm < 0) pwm -= minPWM;
  }

  pwm = constrain(pwm, -maxPWM, maxPWM);

  int leftPwm = pwm + turnPWM;
  int rightPwm = pwm - turnPWM;
  setMotors(leftPwm, rightPwm);

  // Print less often so control loop is smoother
  if (millis() - lastPrint >= 50) {
    lastPrint = millis();
    Serial.print("pitch=");
    Serial.print(pitch, 2);
    Serial.print(" gyro=");
    Serial.print(gyroRate, 2);
    Serial.print(" err=");
    Serial.print(error, 2);
    Serial.print(" out=");
    Serial.print(output, 2);
    Serial.print(" pwm=");
    Serial.println(pwm);
  }

  delay(5);
}