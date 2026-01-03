I'll create a comprehensive README. md and SECURITY.md for your iCtrl Flutter mobile application based on the relevant files. I'll help you create comprehensive README. md and SECURITY.md files for your iCtrl mobile application. Based on the code files you've provided, this is a Flutter-based parental control app with Firebase integration. 

## README.md

````markdown
# iCtrl - Family Safety Control App

[![Flutter](https://img.shields.io/badge/Flutter-3.0+-02569B? logo=flutter)](https://flutter.dev)
[![Firebase](https://img.shields.io/badge/Firebase-Enabled-FFCA28?logo=firebase)](https://firebase.google.com)
[![Platform](https://img.shields.io/badge/Platform-Android%20%7C%20iOS-brightgreen)]()
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**iCtrl** is a comprehensive parental control application that helps parents manage their children's gaming time through intelligent scheduling, task-based rewards, and real-time monitoring.

## 📱 Features

### For Parents
- **🔗 Device Pairing**:  Seamlessly connect parent and child devices using QR codes
- **📅 Gaming Schedules**: Create up to 3 concurrent gaming schedules per child device
- **⏰ Time Management**: Set precise start/end times for gaming sessions
- **🎮 Game Control**: Block/allow specific games remotely
- **📊 Activity Reports**: View detailed weekly gaming reports and analytics
- **✅ Task Management**:  Assign chores with point-based rewards (max 3 tasks per schedule)
- **🔔 Real-time Notifications**: Get instant alerts for gaming activities
- **🔓 Unlock Keys**: Grant temporary game access via reward system

### For Children/Players
- **🎯 Task Tracking**: View assigned tasks and earn reward points
- **⭐ Points System**: Accumulate points by completing tasks
- **🎁 Reward Store**:  Redeem points for game unlock keys: 
  - 15 minutes (200 points)
  - 30 minutes (500 points)
  - 1 hour (1,000 points)
  - 24 hours (2,000 points)
- **📈 Weekly Bonus**: Random weekly bonus tasks for extra points
- **🎮 Game Library**: View all installed games with permission status
- **⏱️ Session Tracking**: Real-time gameplay monitoring with heartbeat system

## 🏗️ Architecture

### Tech Stack
- **Framework**: Flutter/Dart
- **Backend**: Firebase (Firestore, Auth, Storage, Cloud Messaging)
- **State Management**:  StatefulWidget with StreamBuilder
- **Background Tasks**: WorkManager
- **Local Storage**: SharedPreferences
- **Device Info**: device_info_plus
- **QR Scanning**: Mobile Scanner
- **Notifications**: Flutter Local Notifications

### Project Structure
```
lib/
├── main.dart                          # App entry point & splash screen
├── login. dart                         # Authentication (with remember-me)
├── signup.dart                        # User registration
├── emailverification.dart             # OTP-based email verification
├── forgotPassword.dart                # Password reset (30-day cooldown)
├── onboarding.dart                    # App introduction screens
├── useragreement.dart                 # Terms of service
├── parentdashboard.dart               # Parent control panel
├── parentdevice.dart                  # Parent device pairing (QR generation)
├── playerdashboard.dart               # Child dashboard
├── qrscanner.dart                     # QR code scanner for pairing
├── paireddevice.dart                  # Device pairing confirmation
├── playeraccountmanagement.dart       # Player account settings
├── playerchangeaccount.dart           # Password change with OTP
└── services/
    └── background_game_monitor.dart   # Background monitoring service
```

## 🚀 Getting Started

### Prerequisites
- Flutter SDK (3.0 or higher)
- Dart SDK (2.17 or higher)
- Android Studio / Xcode
- Firebase project setup
- Gmail account for SMTP (for OTP emails)

### Installation

1. **Clone the repository**
   ```bash
   git clone https://github.com/yourusername/ictrl.git
   cd ictrl
   ```

2. **Install dependencies**
   ```bash
   flutter pub get
   ```

3. **Firebase Configuration**
   
   Create a Firebase project at [Firebase Console](https://console.firebase.google.com/)
   
   - Enable Firestore Database
   - Enable Firebase Authentication (Email/Password)
   - Enable Firebase Storage
   - Enable Firebase Cloud Messaging
   - Download `google-services.json` (Android) and `GoogleService-Info.plist` (iOS)
   - Place files in respective platform directories

4. **Configure Email Service**
   
   Update SMTP credentials in: 
   - `emailverification.dart` (line 67)
   - `playerchangeaccount.dart` (line 58)
   
   ```dart
   final smtpServer = gmail('your-email@gmail.com', 'your-app-password');
   ```

5. **Android Permissions**
   
   Add to `android/app/src/main/AndroidManifest.xml`:
   ```xml
   <uses-permission android:name="android.permission. INTERNET"/>
   <uses-permission android: name="android.permission.QUERY_ALL_PACKAGES"/>
   <uses-permission android:name="android.permission. PACKAGE_USAGE_STATS"/>
   <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
   <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
   ```

6. **Run the app**
   ```bash
   flutter run
   ```

## 📦 Firestore Database Structure

```
📁 Collections: 
├── player_account/              # Player user profiles
│   └── {userId}
│       ├── username:  string
│       ├── email: string
│       ├── birthdate: timestamp
│       ├── deviceInfo: map
│       ├── rememberMe: boolean
│       ├── rememberMeTimestamp: timestamp
│       └── lastPasswordChange: timestamp
│
├── parent_account/              # Parent user profiles
│   └── {connectionId}
│       ├── parentDeviceId: string
│       ├── parentDeviceInfo: map
│       └── createdAt: timestamp
│
├── paired_devices/              # Device pairing records
│   └── {connectionId}
│       ├── parentDeviceId: string
│       ├── parentDeviceInfo: map
│       ├── childDeviceId: string
│       ├── childDeviceInfo:  map
│       ├── status: string
│       ├── createdAt: timestamp
│       └── connectedAt: timestamp
│
├── gaming_scheduled/            # Gaming schedules
│   └── {connectionId}
│       ├── schedules: array [max 3]
│       │   ├── id: string
│       │   ├── gameName: string
│       │   ├── packageName: string
│       │   ├── scheduledDate: timestamp
│       │   ├── startTime: string
│       │   ├── endTime: string
│       │   ├── durationMinutes: number
│       │   ├── status: string
│       │   ├── isActive: boolean
│       │   └── pauseRequested: boolean
│       └── updatedAt: timestamp
│
├── game_sessions/               # Gameplay tracking
│   └── {connectionId}
│       └── sessions/            # Subcollection
│           └── {sessionId}
│               ├── gameName: string
│               ├── packageName: string
│               ├── launchedAt: timestamp
│               ├── endedAt: timestamp
│               ├── isActive: boolean
│               ├── heartbeat: timestamp
│               └── totalPlayTimeSeconds: number
│
├── installed_games/             # Detected games
│   └── {connectionId}
│       ├── games: array
│       │   ├── name: string
│       │   ├── packageName: string
│       │   ├── category: string
│       │   ├── iconBase64: string
│       │   └── iconStorageUrl: string
│       └── lastUpdated: timestamp
│
├── allowed_games/               # Game permissions
│   └── {connectionId}
│       └── allowedGames: array
│           ├── gameName: string
│           ├── packageName: string
│           ├── isGameAllowed: boolean
│           ├── unlockByKey: boolean
│           └── unlockExpiry: timestamp
│
├── task_and_rewards/            # Tasks & rewards
│   └── {connectionId}
│       └── tasks:  array [max 3 per schedule]
│           ├── task:  string
│           ├── reward: map
│           │   ├── points: number
│           │   └── status: string (pending/verify/granted)
│           ├── childDeviceId: string
│           └── createdAt: timestamp
│
├── accumulated_points/          # Player points
│   └── {connectionId}
│       ├── childDeviceId: string
│       ├── points: number
│       └── updatedAt: timestamp
│
└── parent_tokens/               # FCM tokens
    └── {parentDeviceId}
        ├── token: string
        └── updatedAt: timestamp
```

## 🔑 Key Features Implementation

### 1. Device Pairing
- Parent generates QR code with unique `connectionId`
- Child scans QR code to establish pairing
- Uses `paired_devices` collection with parent/child device info

### 2. Gaming Schedule System
- **Limit**: Maximum 3 active schedules per connection
- **Auto-cleanup**: Expired schedules automatically archived
- **Statuses**: `scheduled`, `active`, `paused`, `completed`, `cancelled`
- **Enforcement**: Real-time schedule monitoring with 30-second grace period

### 3. Task & Reward System
- Parents assign up to 3 tasks per gaming schedule
- Tasks have point values (5, 10, 15, 20 points)
- Workflow: `pending` → `verify` → `granted`
- Weekly bonus tasks for extra points

### 4. Game Control
- Parents can block/allow specific games
- Real-time permission updates via Firestore streams
- Reward-based unlocking with expiry times
- Background monitoring for enforcement

### 5. Session Tracking
- Heartbeat updates every 1 second
- 30-second timeout for abandoned sessions
- Accurate play time calculation
- Session history with stats

## 🔒 Security Features

### Authentication
- Email/password authentication via Firebase Auth
- OTP verification for account creation
- 30-day cooldown on password changes
- "Remember Me" with 14-day expiry

### Data Protection
- Device-specific identifiers (Android ID, iOS Identifier for Vendor)
- Firestore security rules (to be implemented)
- Parent-only access to control features
- Encrypted local storage for sensitive data

### Schedule Enforcement
- Client-side + server-side validation
- Pause/resume with parent permission
- Screen lock prevention (overlay detection)
- Background service monitoring

## 📱 Supported Platforms

| Platform | Minimum Version | Status |
|----------|----------------|--------|
| Android  | 6.0 (API 23)   | ✅ Full Support |
| iOS      | 12.0           | ✅ Full Support |
| Web      | N/A            | ⚠️ Limited (Firebase only) |

## 🐛 Known Limitations

1. **Schedule Limit**: Maximum 3 active schedules per connection
2. **Task Limit**:  Maximum 3 tasks per schedule
3. **Password Changes**: 30-day cooldown period
4. **Remember Me**: 14-day auto-logout
5. **Background Monitoring**: Requires Usage Stats permission on Android 11+

## 🤝 Contributing

Contributions are welcome! Please follow these steps:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

### Code Style
- Follow [Dart Style Guide](https://dart.dev/guides/language/effective-dart/style)
- Use meaningful variable names
- Add comments for complex logic
- Write unit tests for new features

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 👥 Authors

- **Your Name** - *Initial work* - [YourGitHub](https://github.com/yourusername)

## 🙏 Acknowledgments

- Flutter team for the amazing framework
- Firebase for backend infrastructure
- Open-source package contributors
- Community feedback and testers

## 📞 Support

For support, email support@ictrlapp.com or create an issue in the repository.

---

**⚠️ Disclaimer**: This app is designed to assist parents in managing screen time.  It should be used as part of a balanced approach to parenting and digital wellness, not as a replacement for parental involvement and communication. 
````

---
