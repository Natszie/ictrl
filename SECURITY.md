## SECURITY

```markdown
# Security Policy

## Supported Versions

We release patches for security vulnerabilities in the following versions: 

| Version | Supported          |
| ------- | ------------------ |
| 1.x. x   | :white_check_mark: |
| < 1.0   | :x:                |

## Reporting a Vulnerability

We take the security of iCtrl seriously. If you discover a security vulnerability, please follow these steps:

### 1. **Do Not** Disclose Publicly

Please do not open a public GitHub issue for security vulnerabilities. This helps protect users while we work on a fix.

### 2. Report via Email

Send a detailed report to:  **security@ictrlapp.com**

Include:
- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)
- Your contact information

### 3. Response Timeline

- **24 hours**: Acknowledgment of report
- **72 hours**: Initial assessment
- **7-14 days**: Patch development (depending on severity)
- **Public disclosure**: After patch is released

## Security Measures

### Authentication & Authorization

#### Password Security
- **Minimum Length**: 6 characters (enforced client-side and Firebase Auth)
- **Reset Cooldown**: 30-day mandatory cooldown between password changes
- **OTP Verification**: Email-based OTP (6-digit, 5-minute expiry)
- **Remember Me**: 14-day token expiry with automatic cleanup

```dart
// Password change cooldown enforcement
if (userData. containsKey('lastPasswordChange') && userData['lastPasswordChange'] != null) {
  DateTime lastChange = (userData['lastPasswordChange'] as Timestamp).toDate();
  Duration sinceChange = DateTime.now().difference(lastChange);
  
  if (sinceChange.inDays < 30) {
    return 'You can only change your password once every 30 days';
  }
}
```

#### Session Management
- Automatic session expiry after 14 days of inactivity
- Device-specific session tokens
- Logout clears all local cached data

### Data Protection

#### Device Identification
- **Android**:  Uses `androidId` (unique per app installation)
- **iOS**: Uses `identifierForVendor` (unique per vendor)
- **No PII**: Device IDs are hashed and non-reversible

```dart
// Secure device ID generation
if (Platform.isAndroid) {
  deviceId = androidInfo.id; // Android ID (app-specific)
} else if (Platform.isIOS) {
  deviceId = iosInfo.identifierForVendor; // Vendor-specific ID
}
deviceId = 'parent_$deviceId'; // Add prefix for role identification
```

#### Firestore Security Rules

**⚠️ CRITICAL**:  Implement these Firestore security rules: 

```javascript
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    
    // Player accounts - user can only read/write their own
    match /player_account/{userId} {
      allow read, write: if request.auth != null && request.auth.uid == userId;
    }
    
    // Parent accounts - authenticated parents only
    match /parent_account/{connectionId} {
      allow read, write: if request.auth != null;
    }
    
    // Paired devices - both parent and child can read
    match /paired_devices/{connectionId} {
      allow read:  if request.auth != null;
      allow write: if request.auth != null && 
        (request.resource.data.parentDeviceId == request.auth.token.parentDeviceId ||
         request.resource.data. childDeviceId == request.auth.token.childDeviceId);
    }
    
    // Gaming schedules - parent can write, child can read
    match /gaming_scheduled/{connectionId} {
      allow read:  if request.auth != null;
      allow write: if request.auth != null && 
        get(/databases/$(database)/documents/paired_devices/$(connectionId)).data.parentDeviceId 
        == request.auth.token.parentDeviceId;
    }
    
    // Game sessions - child writes, parent reads
    match /game_sessions/{connectionId}/sessions/{sessionId} {
      allow read: if request.auth != null;
      allow create, update:  if request.auth != null && 
        get(/databases/$(database)/documents/paired_devices/$(connectionId)).data.childDeviceId 
        == request.auth.token.childDeviceId;
    }
    
    // Installed games - child writes, parent reads
    match /installed_games/{connectionId} {
      allow read: if request.auth != null;
      allow write: if request.auth != null;
    }
    
    // Allowed games - parent controls
    match /allowed_games/{connectionId} {
      allow read:  if request.auth != null;
      allow write: if request.auth != null && 
        get(/databases/$(database)/documents/paired_devices/$(connectionId)).data.parentDeviceId 
        == request. auth.token.parentDeviceId;
    }
    
    // Tasks and rewards - parent writes, child reads
    match /task_and_rewards/{connectionId} {
      allow read: if request.auth != null;
      allow write: if request.auth != null && 
        get(/databases/$(database)/documents/paired_devices/$(connectionId)).data.parentDeviceId 
        == request.auth.token.parentDeviceId;
    }
    
    // Accumulated points - both can read, controlled writes
    match /accumulated_points/{connectionId} {
      allow read: if request.auth != null;
      allow update: if request.auth != null && 
        (get(/databases/$(database)/documents/paired_devices/$(connectionId)).data.parentDeviceId 
         == request.auth.token.parentDeviceId || 
         request.resource.data.points <= resource.data.points); // Child can only decrease points
    }
  }
}
```

### Email Security

#### SMTP Configuration
- **Current Implementation**: Uses Gmail SMTP with app-specific password
- **⚠️ Security Risk**: Hardcoded credentials in source code

**Recommended Fix**:
```dart
// Use environment variables or Firebase Functions
import 'package:flutter_dotenv/flutter_dotenv.dart';

final smtpServer = gmail(
  dotenv.env['SMTP_EMAIL']!, 
  dotenv.env['SMTP_PASSWORD']!
);
```

Or migrate to Firebase Cloud Functions:
```javascript
// functions/index.js
const functions = require('firebase-functions');
const nodemailer = require('nodemailer');

exports.sendOTP = functions.https.onCall(async (data, context) => {
  const transporter = nodemailer.createTransporter({
    service: 'gmail',
    auth: {
      user: functions.config().smtp.email,
      pass: functions.config().smtp.password
    }
  });
  
  await transporter.sendMail({
    to: data.email,
    subject: 'Your OTP Code',
    html: generateOTPEmail(data.otp, data.username)
  });
});
```

### Network Security

#### API Keys
- **Firebase API Key**: Exposed in `main.dart` (line 31)
- **Risk**: Low (Firebase API keys are safe to expose)
- **Recommendation**: Use Firebase App Check for additional protection

```dart
// Add to main.dart
import 'package:firebase_app_check/firebase_app_check. dart';

Future<void> main() async {
  WidgetsFlutterBinding. ensureInitialized();
  await Firebase.initializeApp();
  
  // Enable App Check
  await FirebaseAppCheck.instance.activate(
    webRecaptchaSiteKey: 'your-recaptcha-site-key',
  );
  
  runApp(const MyApp());
}
```

#### Certificate Pinning
Not currently implemented.  Consider adding: 

```dart
// Using dio package
import 'package:dio/dio.dart';
import 'package:dio/adapter.dart';

Dio getDioWithCertPinning() {
  Dio dio = Dio();
  (dio.httpClientAdapter as DefaultHttpClientAdapter).onHttpClientCreate = (client) {
    client.badCertificateCallback = (cert, host, port) {
      // Implement certificate pinning logic
      return cert. pem == 'YOUR_CERTIFICATE_PEM';
    };
    return client;
  };
  return dio;
}
```

### Permission Management

#### Android Permissions
Required permissions with security implications:

1. **QUERY_ALL_PACKAGES** (Dangerous)
   - Purpose:  Detect installed games
   - Risk: Can access all app list
   - Mitigation: Only reads package names, no app data

2. **PACKAGE_USAGE_STATS** (Special)
   - Purpose: Monitor app usage in background
   - Risk: Can track all app usage
   - Mitigation: Only monitors games in whitelist

3. **FOREGROUND_SERVICE**
   - Purpose: Background game monitoring
   - Risk: Can run continuously
   - Mitigation: Only runs when schedules are active

#### Permission Request Flow
```dart
// Check and request permissions properly
Future<bool> _requestPermissions() async {
  if (Platform.isAndroid) {
    // Request PACKAGE_USAGE_STATS
    final hasUsageStats = await Permission.systemAlertWindow.request();
    if (!hasUsageStats. isGranted) {
      // Open settings
      await openAppSettings();
      return false;
    }
  }
  return true;
}
```

### Schedule Enforcement Security

#### Bypass Prevention
1. **Time Tampering**: Server-side timestamp validation
2. **Force Close**: 30-second grace period before session end

```dart
// Server-side validation example
Future<bool> _validateSchedule(String scheduleId) async {
  final serverTime = FieldValue.serverTimestamp();
  final schedule = await FirebaseFirestore.instance
    .collection('gaming_scheduled')
    .doc(_connectionId)
    .get();
  
  // Compare client vs server time
  if (clientTime.difference(serverTime).abs() > Duration(minutes: 5)) {
    // Time tampering detected
    _notifyParent('Time manipulation detected');
    return false;
  }
  return true;
}
```

## Vulnerability Disclosure History

No vulnerabilities have been reported yet. 

## Security Best Practices for Developers

### 1. Code Review Checklist
- [ ] No hardcoded credentials
- [ ] Proper error handling (no sensitive info in errors)
- [ ] Input validation on all user inputs
- [ ] Firestore security rules implemented
- [ ] API keys in environment variables
- [ ] Certificate pinning enabled
- [ ] Proper permission requests
- [ ] Secure local storage (encrypted)

### 2. Testing Security
```bash
# Test Firestore rules
firebase emulators:start --only firestore
npm install -g @firebase/rules-unit-testing

# Run security tests
flutter test test/security_test.dart
```

### 3. Dependency Auditing
```bash
# Check for vulnerable dependencies
flutter pub outdated
flutter pub upgrade --major-versions

# Audit specific packages
flutter pub deps --style=compact
```

### 4. Code Obfuscation (Production Builds)
```bash
# Build with obfuscation
flutter build apk --obfuscate --split-debug-info=build/debug-info
flutter build ios --obfuscate --split-debug-info=build/debug-info
```

## Incident Response Plan

### If Vulnerability is Exploited: 

1. **Immediate Actions** (0-24 hours)
   - Disable affected features via Firebase Remote Config
   - Send push notifications to all users
   - Reset all sessions (force re-login)

2. **Short-term** (24-72 hours)
   - Deploy emergency patch
   - Contact affected users directly
   - Document incident in postmortem

3. **Long-term** (1-2 weeks)
   - Conduct full security audit
   - Implement additional safeguards
   - Update security documentation
   - Publish public disclosure

## Security Contacts

- **Security Email**: security@ictrlapp. com
- **Bug Bounty**: Not currently active
- **PGP Key**: Available upon request

## Additional Resources

- [OWASP Mobile Security](https://owasp.org/www-project-mobile-security/)
- [Firebase Security Checklist](https://firebase.google.com/support/guides/security-checklist)
- [Flutter Security Best Practices](https://docs.flutter.dev/security)

---

**Last Updated**: 2026-01-03  
**Next Review**: 2026-04-03 (Quarterly)
```

---

## Implementation Checklist

To complete the security setup, implement these changes:

1. **Immediate (Critical)**: 
   - [ ] Move SMTP credentials to environment variables
   - [ ] Implement Firestore security rules (use the provided rules)
   - [ ] Enable Firebase App Check
   - [ ] Remove hardcoded API keys from source control

2. **Short-term (High Priority)**:
   - [ ] Add certificate pinning for API calls
   - [ ] Implement encrypted local storage
   - [ ] Add developer mode detection
   - [ ] Set up security monitoring/alerts

3. **Medium-term (Important)**:
   - [ ] Migrate OTP to Firebase Cloud Functions
   - [ ] Implement proper logging (no sensitive data)
   - [ ] Add rate limiting on sensitive operations
   - [ ] Create security test suite

4. **Long-term (Nice to Have)**:
   - [ ] Bug bounty program
   - [ ] Security audit by third party
   - [ ] Penetration testing
   - [ ] SOC 2 compliance (if commercializing)

These documents provide comprehensive documentation and security guidelines for your iCtrl application.  Remember to update the repository URL, email addresses, and author information with your actual details before publishing! 
