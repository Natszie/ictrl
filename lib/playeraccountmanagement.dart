import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'login.dart';
import 'playerchangeaccount.dart';

class PlayerAccountManagementScreen extends StatefulWidget {
  final String username;
  final String? connectionId;
  final String? email;

  const PlayerAccountManagementScreen({
    Key? key,
    required this.username,
    required this.connectionId,
    required this.email,
  }) : super(key: key);

  @override
  State<PlayerAccountManagementScreen> createState() => _PlayerAccountManagementScreenState();
}

class _PlayerAccountManagementScreenState extends State<PlayerAccountManagementScreen> {
  static const Color accentColor = Color(0xFFE8956C);
  static const Color backgroundTop = Color(0xFF2D3142);
  static const Color backgroundBottom = Color(0xFF1A1D2E);

  bool _canChangePassword = true;
  int _daysRemaining = 0;

  @override
  void initState() {
    super.initState();
    _checkCooldown();
  }

  Future<void> _checkCooldown() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final doc = await FirebaseFirestore.instance.collection('player_account').doc(user.uid).get();
    final lastChange = doc.data()?['lastPasswordChange'] as Timestamp?;
    if (lastChange != null) {
      final daysSinceChange = DateTime.now().difference(lastChange.toDate()).inDays;
      if (daysSinceChange < 30) {
        setState(() {
          _canChangePassword = false;
          _daysRemaining = 30 - daysSinceChange;
        });
      } else {
        setState(() {
          _canChangePassword = true;
        });
      }
    }
  }

  String maskEmail(String email) {
    final atIndex = email.indexOf('@');
    if (atIndex <= 1) return email;
    final local = email.substring(0, atIndex);
    final domain = email.substring(atIndex);
    final maskedLocal = local[0] + '*' * (local.length - 1);
    return '$maskedLocal$domain';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("Account Management"),
        backgroundColor: backgroundTop,
        elevation: 0,
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [backgroundTop, backgroundBottom],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Row(
                  children: [
                    CircleAvatar(
                      radius: 28,
                      backgroundColor: accentColor,
                      child: Icon(Icons.account_circle, color: Colors.white, size: 32),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.username.isEmpty ? 'Player' : widget.username,
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          Text(
                            widget.email == null ? '' : maskEmail(widget.email!),
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.white70,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 32),
                // Account Info Card
                Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.06),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white.withOpacity(0.22), width: 1),
                  ),
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("Account Details", style: TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 18, color: accentColor,
                      )),
                      const SizedBox(height: 18),
                      _InfoRow(label: "Username", value: widget.username),
                      _InfoRow(label: "Email", value: widget.email == null ? '' : maskEmail(widget.email!)),
                      _InfoRow(label: "Connection ID", value: widget.connectionId ?? 'Not paired'),
                    ],
                  ),
                ),
                const SizedBox(height: 40),
                // Password reset
                if (_canChangePassword)
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: accentColor,
                      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 3,
                    ),
                    icon: Icon(Icons.lock_reset, color: Colors.white),
                    label: Text(
                      "Change Password",
                      style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 16),
                    ),
                    onPressed: widget.email == null
                        ? null
                        : () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) => PlayerChangeAccountScreen(
                            username: widget.username,
                            email: widget.email!,
                          ),
                        ),
                      );
                    },
                  ),
                if (!_canChangePassword)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      "You can change your password again in $_daysRemaining days.",
                      style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                  ),
                const SizedBox(height: 24),
                // Sign out
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red.shade700,
                    padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  icon: Icon(Icons.logout, color: Colors.white),
                  label: Text(
                    "Sign Out",
                    style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 15),
                  ),
                  onPressed: () async {
                    await FirebaseAuth.instance.signOut();
                    Navigator.of(context).pushAndRemoveUntil(
                      MaterialPageRoute(builder: (context) => LoginPage()),
                          (Route<dynamic> route) => false,
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Text("$label:", style: TextStyle(
            color: Colors.white70,
            fontWeight: FontWeight.w600,
            fontSize: 15,
          )),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w500,
                fontSize: 15,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ),
    );
  }
}