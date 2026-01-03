# iCtrl - Family Gaming Control System

A comprehensive Flutter-based parental control application that helps parents manage and monitor their children's gaming activities on Android devices.

## 📋 Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Architecture](#architecture)
- [Installation](#installation)
- [Configuration](#configuration)
- [Usage](#usage)
- [Technical Details](#technical-details)
- [Contributing](#contributing)
- [License](#license)

## 🎯 Overview

iCtrl is a dual-dashboard application designed to help families establish healthy gaming habits.  It provides parents with tools to set gaming schedules, assign tasks, and monitor gameplay while giving children a transparent view of their gaming time and rewards.

### Key Components

- **Parent Dashboard**: Comprehensive control panel for managing gaming schedules, tasks, and rewards
- **Player Dashboard**: Child-friendly interface showing available games, schedules, and tasks
- **Background Monitoring**: Real-time game session tracking and enforcement
- **QR Code Pairing**: Secure device pairing mechanism

## ✨ Features

### For Parents

- **📅 Gaming Schedule Management**
  - Create, edit, and delete gaming schedules
  - Set specific time windows for gameplay
  - Recurring schedule support
  - Maximum 3 active schedules per connection
  - Automatic schedule status updates (scheduled → active → completed)

- **📋 Task Assignment System**
  - Assign chores/tasks to children
  - Set point-based rewards
  - Verify task completion
  - Track reward status (pending → verify → granted)

- **🎮 Game Permission Control**
  - View all installed games on child devices
  - Allow/block specific games
  - Real-time permission updates
  - Cloud-synced game library

- **📊 Activity Monitoring**
  - Live gaming session tracking
  - Weekly play time reports
  - Game-by-game analytics
  - Session history with timestamps

- **🔗 Device Management**
  - QR code-based device pairing
  - Multiple child device support
  - Connection status monitoring
  - Firebase Cloud Messaging integration

### For Players (Children)

- **🎯 Gaming Dashboard**
  - View available games and schedules
  - See active gaming sessions with real-time timers
  - Check upcoming schedule reminders
  - Weekly gaming report

- **✅ Task Management**
  - View assigned tasks
  - Complete tasks to earn points
  - 3-minute delay before task completion (anti-cheat)
  - Track reward verification status

- **🏆 Reward System**
  - Accumulate points from completed tasks
  - Redeem rewards for: 
    - 15 minutes gameplay unlock (200 pts)
    - 30 minutes gameplay unlock (500 pts)
    - 1 hour gameplay unlock (1000 pts)
    - 24 hours gameplay unlock (2000 pts)
  - Time-limited unlock keys
  - Voucher inventory system

- **📱 Real-time Notifications**
  - Game start/end notifications
  - Schedule reminders (15 min, 5 min before)
  - Time warning notifications
  - Active session indicators

## 🏗️ Architecture

### Tech Stack

- **Framework**: Flutter 3.x
- **Language**: Dart
- **Backend**: Firebase
  - Firestore (Real-time Database)
  - Cloud Storage (Game icons)
  - Cloud Messaging (Push notifications)
  - Authentication
- **State Management**: setState (StatefulWidget)
- **Local Storage**: SharedPreferences
- **Background Processing**: WorkManager

### Firebase Structure

```
firestore/
├── parent_account/
│   └── {parentDeviceId}
│       ├── username
│       ├── parentDeviceId
│       └── deviceInfo
│
├── player_account/
│   └── {childDeviceId}
│       ├── username
│       ├── email
│       └── deviceInfo
│
├── paired_devices/
│   └── {connectionId}
│       ├── parentDeviceId
│       ├── childDeviceId
│       ├── parentDeviceInfo
│       ├── childDeviceInfo
│       ├── connectionStatus
│       └── pairedAt
│
├── gaming_scheduled/
│   └── {connectionId}
│       ├── parentDeviceId
│       ├── connectionId
│       ├── schedules[]
│       │   ├── id
│       │   ├── gameName
│       │   ├── packageName
│       │   ├── scheduledDate
│       │   ├── startTime
│       │   ├── endTime
│       │   ├── durationMinutes
│       │   ├── status (scheduled|active|paused|completed)
│       │   ├── isActive
│       │   └── isRecurring
│       └── updatedAt
│
├── installed_games/
│   └── {connectionId}
│       ├── deviceId
│       ├── games[]
│       │   ├── name
│       │   ├── packageName
│       │   ├── category
│       │   ├── iconBase64
│       │   └── iconStorageUrl
│       └── lastUpdated
│
├── allowed_games/
│   └── {connectionId}
│       ├── parentDeviceId
│       ├── connectionId
│       ├── allowedGames[]
│       │   ├── gameName
│       │   ├── packageName
│       │   ├── isGameAllowed
│       │   ├── unlockByKey
│       │   ├── unlockExpiry
│       │   └── updatedAt
│       └── updatedAt
│
├── game_sessions/
│   └── {connectionId}/
│       └── sessions/
│           └── {sessionId}
│               ├── gameName
│               ├── packageName
│               ├── launchedAt
│               ├── endedAt
│               ├── isActive
│               ├── totalPlayTimeSeconds
│               ├── heartbeat
│               └── childDeviceId
│
├── task_and_rewards/
│   └── {connectionId}
│       ├── parentDeviceId
│       ├── connectionId
│       ├── tasks[]
│       │   ├── task
│       │   ├── reward. points
│       │   ├── reward.status (pending|verify|granted)
│       │   ├── childDeviceId
│       │   └── createdAt
│       └── updatedAt
│
├── accumulated_points/
│   └── {connectionId}
│       ├── childDeviceId
│       ├── points
│       └── updatedAt
│
└── redeemed_rewards/
    └── {connectionId}/
        └── vouchers/
            └── {voucherId}
                ├── type
                ├── name
                ├── minutes
                ├── isUsed
                └── createdAt
```

### Key Classes

#### Parent Dashboard (`parentdashboard.dart`)
- `ParentDashboard`: Main parent interface with 5 tabs
- `_AddScheduleDialog`: Schedule creation/editing form
- `_AddTaskDialog`: Task assignment form
- Connection management and real-time listeners

#### Player Dashboard (`playerdashboard.dart`)
- `PlayerDashboard`: Main child interface with 5 tabs
- `GameSession`: Active session tracking
- `GameSchedule`: Schedule data model
- `TaskReward`: Task/reward data model
- `RedeemableReward`: Point-based rewards

#### Background Services
- `EnhancedBackgroundGameMonitor`: WorkManager-based game monitoring
- `GameplayNotificationService`: Local notification management
- `GameIconService`: Icon caching and Firebase Storage integration

## 🚀 Installation

### Prerequisites

- Flutter SDK 3.0 or higher
- Android Studio / VS Code
- Firebase account
- Android device for testing (required for game detection)

### Setup Steps

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

   a. Create a new Firebase project at [Firebase Console](https://console.firebase.google.com)
   
   b. Add Android app to your Firebase project
   
   c. Download `google-services.json` and place it in `android/app/`
   
   d. Update `android/build.gradle`:
   ```gradle
   dependencies {
       classpath 'com.google. gms:google-services:4.3.15'
   }
   ```
   
   e. Update `android/app/build.gradle`:
   ```gradle
   apply plugin: 'com.google.gms.google-services'
   ```

4. **Update Firebase config in `main.dart`** (for web):
```dart
await Firebase.initializeApp(options: FirebaseOptions(
    apiKey: "YOUR_API_KEY",
    authDomain: "YOUR_AUTH_DOMAIN",
    projectId: "YOUR_PROJECT_ID",
    storageBucket: "YOUR_STORAGE_BUCKET",
    messagingSenderId: "YOUR_MESSAGING_SENDER_ID",
    appId: "YOUR_APP_ID"
));
```

5. **Configure Android permissions** in `android/app/src/main/AndroidManifest.xml`:
```xml
<uses-permission android:name="android.permission. INTERNET" />
<uses-permission android:name="android.permission. QUERY_ALL_PACKAGES" />
<uses-permission android:name="android.permission. PACKAGE_USAGE_STATS" />
<uses-permission android:name="android.permission.WAKE_LOCK" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
```

6. **Run the app**
```bash
flutter run
```

## ⚙️ Configuration

### Firebase Rules

**Firestore Security Rules** (example):
```javascript
rules_version = '2';
service cloud. firestore {
  match /databases/{database}/documents {
    match /paired_devices/{document=**} {
      allow read, write: if true;
    }
    match /gaming_scheduled/{document=**} {
      allow read, write: if true;
    }
    match /game_sessions/{connectionId}/sessions/{sessionId} {
      allow read, write: if true;
    }
    match /allowed_games/{document=**} {
      allow read, write: if true;
    }
    match /task_and_rewards/{document=**} {
      allow read, write: if true;
    }
    match /accumulated_points/{document=**} {
      allow read, write: if true;
    }
  }
}
```

**Storage Rules**:
```javascript
rules_version = '2';
service firebase. storage {
  match /b/{bucket}/o {
    match /game_icons/{iconId} {
      allow read: if true;
      allow write: if request.auth != null;
    }
  }
}
```

### WorkManager Configuration

Background monitoring uses WorkManager with the following setup:

```dart
await Workmanager().initialize(
  enhancedCallbackDispatcher,
  isInDebugMode: true, // Set to false in production
);
```

## 📖 Usage

### Parent Workflow

1. **Initial Setup**
   - Install app on parent device
   - Launch app (automatically detects as parent device)
   - Navigate to Dashboard

2. **Pair Child Device**
   - On parent:  Generate QR code (via "Pair Device" button)
   - On child: Scan QR code
   - Confirm pairing

3. **Create Gaming Schedule**
   - Go to "Schedule" tab
   - Tap "Add Gaming Schedule"
   - Select child device
   - Choose game from installed games list
   - Set date, start time, end time
   - Optional: Add tasks for the schedule
   - Save schedule

4. **Manage Games**
   - Go to "Manage" tab
   - View all installed games on child device
   - Toggle game permissions (Allow/Block)
   - Changes sync immediately

5. **Assign Tasks**
   - Go to "Tasks" tab
   - Tap "Add Task"
   - Select child device
   - Choose task from predefined list or create custom
   - Assign point value
   - Save task

6. **Monitor Activity**
   - Dashboard shows:
     - Connected devices
     - Active gaming sessions (LIVE indicator)
     - Today's overview
     - Recent activity
     - Weekly gaming report

### Player Workflow

1. **Initial Setup**
   - Install app on child device
   - Launch app
   - Create account (username, email, password)
   - Wait for parent to initiate pairing

2. **View Schedules**
   - Go to "Schedule" tab
   - See all gaming schedules
   - Green border = Available now
   - Orange badge = Upcoming
   - Tap schedule to launch game (if available)

3. **Play Games**
   - Available games shown in "Games" tab
   - Green "Allowed" badge = Can play
   - Red "Blocked" badge = Cannot play
   - Tap allowed game to launch
   - Real-time session tracking with live timer

4. **Complete Tasks**
   - Go to "Tasks" tab
   - View assigned tasks
   - Wait 3 minutes after task assignment
   - Tap "Complete" to mark as done
   - Status changes to "Waiting for parent's approval"
   - Earn points after parent verification

5. **Redeem Rewards**
   - Accumulated points shown in header
   - Scroll to "Redeem Rewards" section
   - Choose reward tier
   - Select game to unlock
   - Unlocked game shows expiry time

## 🔧 Technical Details

### Schedule Enforcement System

The app uses a multi-layer schedule enforcement mechanism:

1. **Real-time Firestore Listeners**
   - Monitors `gaming_scheduled/{connectionId}` document
   - Updates schedule status automatically
   - Triggers UI updates via `StreamBuilder`

2. **Status Transitions**
   ```
   scheduled → active → completed
            ↓
          paused (manual)
   ```

3. **Auto-Update Timer**
   - Runs every 30 seconds
   - Checks current time against schedule windows
   - Updates status in Firestore
   - Calls `_updateAllowedGamesFromSchedules()`

4. **Allowed Games Sync**
   - Schedule status directly affects `allowed_games` collection
   - Active schedule → game allowed
   - Paused/Completed schedule → game blocked
   - Unlock keys override schedule restrictions

### Game Session Tracking

**Session Lifecycle**: 

1. **Launch Detection**
   ```dart
   await _trackGameLaunch(packageName, gameName);
   ```
   - Creates new session document
   - Sets `isActive: true`
   - Starts heartbeat timer (1-second interval)

2. **Active Monitoring**
   ```dart
   void _startSessionUpdates(String sessionId, String gameName) {
     _realTimeUpdateTimer = Timer.periodic(Duration(seconds: 1), (timer) {
       _updateGameSession(sessionId, gameName);
     });
   }
   ```
   - Updates `totalPlayTimeSeconds` every second
   - Updates `heartbeat` timestamp
   - Triggers UI rebuild for live timer

3. **Session End**
   ```dart
   await _endActiveGameSession();
   ```
   - Sets `isActive: false`
   - Records `endedAt` timestamp
   - Calculates final `totalPlayTimeSeconds`
   - Shows end notification

### Background Monitoring

The app uses WorkManager for persistent background monitoring:

```dart
@pragma('vm:entry-point')
void enhancedCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    await Firebase.initializeApp();
    await EnhancedBackgroundGameMonitor.checkEnhancedGamesInBackground(inputData:  inputData);
    return Future.value(true);
  });
}
```

**Features**:
- Periodic task execution (configurable interval)
- Firebase integration in background
- Game permission enforcement
- Survives app termination

### Icon Caching Strategy

Multi-tier caching for optimal performance:

1. **Local Cache** (Fastest)
   ```dart
   Future<Uint8List? > getCachedIcon(String packageName)
   ```
   - Stores icons in app documents directory
   - MD5 hash-based filename

2. **Direct App Query**
   ```dart
   Future<Uint8List?> fetchAppIcon(String packageName)
   ```
   - Uses `installed_apps` plugin
   - Caches result locally

3. **Firebase Storage** (Fallback)
   ```dart
   Future<String?> getIconFromStorage(String packageName)
   ```
   - Cloud-based icon storage
   - Used when local methods fail

4. **Icon Font Fallback**
   - Material Icons-based fallback
   - Keyword matching for appropriate icon

### Real-time Updates

The app uses Firestore snapshots for real-time synchronization:

**Parent Side**:
```dart
_scheduleStreamSubscription = FirebaseFirestore.instance
    .collection('gaming_scheduled')
    . doc(_connectionId!)
    .snapshots()
    .listen((snapshot) {
      _processScheduleSnapshot(snapshot);
    });
```

**Player Side**:
```dart
_gameSessionsListener = FirebaseFirestore.instance
    .collection('game_sessions')
    . doc(_connectionId!)
    .collection('sessions')
    .where('isActive', isEqualTo: true)
    .snapshots()
    .listen((query) {
      // Update active sessions UI
    });
```

### Notification System

Comprehensive notification categories:

1. **Gameplay Notifications**
   - Game start (ongoing)
   - Live timer updates
   - Game end summary

2. **Schedule Reminders**
   - 15 minutes before
   - 5 minutes before
   - Active schedule alert

3. **Time Warnings**
   - 10 minutes remaining
   - 5 minutes remaining
   - 1 minute remaining

4. **Critical Alerts**
   - Schedule time up
   - Game blocked notification

## 🤝 Contributing

Contributions are welcome! Please follow these guidelines:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit changes (`git commit -m 'Add AmazingFeature'`)
4. Push to branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

### Code Style

- Follow [Effective Dart](https://dart.dev/guides/language/effective-dart) guidelines
- Use meaningful variable/function names
- Comment complex logic
- Maintain consistent formatting

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🐛 Known Issues

1. **Background Monitoring Limitations**
   - Requires battery optimization to be disabled
   - May not work on all Android versions (tested on Android 10+)

2. **Game Detection**
   - Relies on `QUERY_ALL_PACKAGES` permission (Android 11+)
   - Some games may not be detected if permission denied

3. **Icon Loading**
   - First-time icon fetch may be slow
   - Network dependency for Firebase Storage icons

## 🔮 Future Enhancements

- [ ] iOS support
- [ ] Web dashboard for parents
- [ ] Multiple parent accounts
- [ ] Screen time analytics charts
- [ ] Export reports (PDF/CSV)
- [ ] Geofencing restrictions
- [ ] Content filtering
- [ ] App usage limits (beyond games)
- [ ] Family calendar integration
- [ ] Achievement system

## 📞 Support

For issues and questions:
- Open an issue on GitHub
- Email:  support@ictrlapp.com (if applicable)
- Documentation: [Wiki](https://github.com/yourusername/ictrl/wiki)

## 🙏 Acknowledgments

- Flutter team for the amazing framework
- Firebase for backend infrastructure
- `installed_apps` plugin contributors
- `workmanager` plugin contributors
- Material Design for UI components

---

**Made with ❤️ for families seeking healthy digital balance**
