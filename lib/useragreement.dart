// useragreement.dart
import 'package:flutter/material.dart';

class UserAgreementPage extends StatefulWidget {
  const UserAgreementPage({Key? key}) : super(key: key);

  @override
  State<UserAgreementPage> createState() => _UserAgreementPageState();
}

class _UserAgreementPageState extends State<UserAgreementPage> {
  bool _agreedToTerms = false;
  bool _agreedToPrivacy = false;

  @override
  Future<bool> _onWillPop(BuildContext context) async {
    return (await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Exit App'),
        content: const Text('Do you want to exit the app?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Exit'),
          ),
        ],
      ),
    )) ??
        false;
  }

  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () => _onWillPop(context),
      child: Scaffold(
        body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF2D3142), // Dark blue-gray
              Color(0xFF1A1D2E), // Darker blue
            ],
          ),
        ),
        child: SafeArea(
          child: _buildAgreementView(),
        ),
      ),),

    );
  }

  Widget _buildAgreementView() {
    return SingleChildScrollView(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: MediaQuery.of(context).size.height - MediaQuery.of(context).padding.top,
        ),
        child: Column(
          children: [
            // Top illustration area
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Illustration container
                  Container(
                    width: 280,
                    height: 220,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Color(0xFFE8956C), // Warm orange
                          Color(0xFFD4794A), // Darker orange
                        ],
                      ),
                    ),
                    child: Stack(
                      children: [
                        // Background elements
                        Positioned(
                          right: 20,
                          top: 20,
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),
                        // Main illustration
                        Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.security,
                                size: 70,
                                color: Colors.white,
                              ),
                              const SizedBox(height: 15),
                              Text(
                                "Terms & Privacy",
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                        // Decorative elements
                        Positioned(
                          left: 15,
                          bottom: 15,
                          child: Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                        Positioned(
                          right: 30,
                          bottom: 40,
                          child: Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.7),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // Content area
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 20),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    "Before we begin...",
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 15),
                  Text(
                    "Please review and accept our terms to continue using iCtrl.",
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.white.withOpacity(0.8),
                      height: 1.5,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
            // Bottom agreement section
            Padding(
              padding: const EdgeInsets.all(30),
              child: Column(
                children: [
                  // Terms and Privacy Agreement
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(15),
                      border: Border.all(
                        color: Colors.white.withOpacity(0.2),
                      ),
                    ),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Checkbox(
                              value: _agreedToTerms,
                              onChanged: (value) {
                                setState(() {
                                  _agreedToTerms = value ?? false;
                                });
                              },
                              activeColor: const Color(0xFFE8956C),
                              checkColor: Colors.white,
                            ),
                            Expanded(
                              child: GestureDetector(
                                onTap: () {
                                  setState(() {
                                    _agreedToTerms = !_agreedToTerms;
                                  });
                                },
                                child: RichText(
                                  text: TextSpan(
                                    style: TextStyle(
                                      color: Colors.white.withOpacity(0.9),
                                      fontSize: 14,
                                    ),
                                    children: [
                                      const TextSpan(text: "I agree to the "),
                                      WidgetSpan(
                                        child: GestureDetector(
                                          onTap: () => _showTermsModal(context),
                                          child: Text(
                                            "Terms of Service",
                                            style: TextStyle(
                                              color: Color(0xFFE8956C),
                                              fontSize: 14,
                                              decoration: TextDecoration.underline,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Checkbox(
                              value: _agreedToPrivacy,
                              onChanged: (value) {
                                setState(() {
                                  _agreedToPrivacy = value ?? false;
                                });
                              },
                              activeColor: const Color(0xFFE8956C),
                              checkColor: Colors.white,
                            ),
                            Expanded(
                              child: GestureDetector(
                                onTap: () {
                                  setState(() {
                                    _agreedToPrivacy = !_agreedToPrivacy;
                                  });
                                },
                                child: RichText(
                                  text: TextSpan(
                                    style: TextStyle(
                                      color: Colors.white.withOpacity(0.9),
                                      fontSize: 14,
                                    ),
                                    children: [
                                      const TextSpan(text: "I agree to the "),
                                      WidgetSpan(
                                        child: GestureDetector(
                                          onTap: () => _showPrivacyModal(context),
                                          child: Text(
                                            "Privacy Policy",
                                            style: TextStyle(
                                              color: Color(0xFFE8956C),
                                              fontSize: 14,
                                              decoration: TextDecoration.underline,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  // Continue Button
                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: () {
                            Navigator.pop(context);
                          },
                          child: const Text(
                            'Back',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 20),
                      Expanded(
                        flex: 2,
                        child: ElevatedButton(
                          onPressed: (_agreedToTerms && _agreedToPrivacy)
                              ? () {
                            // Navigate to login page
                            Navigator.pushReplacementNamed(context, '/login');
                            // Temporary: Show snackbar until login.dart is created

                          }
                              : null,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFE8956C),
                            foregroundColor: Colors.white,
                            disabledBackgroundColor: Colors.grey.withOpacity(0.3),
                            disabledForegroundColor: Colors.grey.withOpacity(0.6),
                            padding: const EdgeInsets.symmetric(vertical: 15),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(25),
                            ),
                          ),
                          child: const Text(
                            'Continue',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showTermsModal(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return Dialog(
          backgroundColor: Colors.transparent,
          child: Container(
            height: MediaQuery.of(context).size.height * 0.8,
            margin: const EdgeInsets.symmetric(horizontal: 20),
            decoration: BoxDecoration(
              color: const Color(0xFF2D3142),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: Colors.white.withOpacity(0.2),
              ),
            ),
            child: Column(
              children: [
                // Header
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE8956C),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(20),
                      topRight: Radius.circular(20),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Terms of Service',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      GestureDetector(
                        onTap: () => Navigator.pop(context),
                        child: const Icon(
                          Icons.close,
                          color: Colors.white,
                          size: 24,
                        ),
                      ),
                    ],
                  ),
                ),
                // Content
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      _getTermsContent(),
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.9),
                        fontSize: 14,
                        height: 1.5,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showPrivacyModal(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return Dialog(
          backgroundColor: Colors.transparent,
          child: Container(
            height: MediaQuery.of(context).size.height * 0.8,
            margin: const EdgeInsets.symmetric(horizontal: 20),
            decoration: BoxDecoration(
              color: const Color(0xFF2D3142),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: Colors.white.withOpacity(0.2),
              ),
            ),
            child: Column(
              children: [
                // Header
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE8956C),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(20),
                      topRight: Radius.circular(20),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Privacy Policy',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      GestureDetector(
                        onTap: () => Navigator.pop(context),
                        child: const Icon(
                          Icons.close,
                          color: Colors.white,
                          size: 24,
                        ),
                      ),
                    ],
                  ),
                ),
                // Content
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      _getPrivacyContent(),
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.9),
                        fontSize: 14,
                        height: 1.5,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _getTermsContent() {
    return '''
ICTRL - TERMS OF SERVICE

Last Updated: ${DateTime.now().year}

1. ACCEPTANCE OF TERMS

By using iCtrl, you agree to be bound by these Terms of Service. If you do not agree to these terms, please do not use our service.

2. DESCRIPTION OF SERVICE

iCtrl is a parental control application designed to help parents monitor and manage their children's gaming time and activities. Our service includes:

• Gaming time monitoring and tracking
• Smart scheduling for balanced gaming habits
• Task-based reward systems
• Healthy lifestyle promotion tools
• Real-time activity monitoring

3. USER RESPONSIBILITIES

Parents/Guardians:
• Must be 18 years or older to create an account
• Are responsible for setting appropriate gaming limits
• Must ensure child's consent for monitoring activities
• Should regularly review and adjust settings as needed
• Are responsible for maintaining account security

Children/Players:
• Must comply with limits set by parents/guardians
• Should not attempt to bypass or circumvent controls
• Must use the application responsibly
• Should communicate with parents about any concerns

4. GAMING TIME MANAGEMENT

• Parents can set daily and weekly gaming time limits
• The system will automatically enforce these limits
• Emergency overrides are available for parents only
• Gaming sessions may be paused or terminated when limits are reached
• Time tracking includes all monitored gaming activities

5. TASK-BASED REWARDS

• Parents can set up tasks that must be completed to earn gaming time
• Tasks may include household chores, homework, or other activities
• Gaming privileges are linked to task completion
• Parents have full control over task requirements and rewards

6. PRIVACY AND MONITORING

• All monitoring is conducted with parental consent
• Activity logs are stored securely and accessible only to parents
• No personal conversations or private communications are monitored
• Gaming activity data is used solely for parental oversight purposes

7. PROHIBITED USES

You may not use iCtrl to:
• Violate any laws or regulations
• Harass, abuse, or harm others
• Circumvent parental controls
• Share account credentials with unauthorized users
• Interfere with the proper functioning of the service

8. ACCOUNT SUSPENSION/TERMINATION

We reserve the right to suspend or terminate accounts that:
• Violate these terms of service
• Engage in prohibited activities
• Present security risks
• Are inactive for extended periods

9. LIMITATION OF LIABILITY

iCtrl is provided "as is" without warranties. We are not liable for:
• Any damages resulting from use of the service
• Technical issues or service interruptions
• Consequences of parental control decisions
• Third-party content or services

10. MODIFICATIONS

We may modify these terms at any time. Continued use of iCtrl after changes constitutes acceptance of new terms.

11. CONTACT INFORMATION

For questions about these terms, please contact our support team through the app or visit our website.

By clicking "I agree," you acknowledge that you have read, understood, and agree to be bound by these Terms of Service.
''';
  }

  String _getPrivacyContent() {
    return '''
ICTRL - PRIVACY POLICY

Last Updated: ${DateTime.now().year}

1. INFORMATION WE COLLECT

Gaming Activity Data:
• Time spent on games and applications
• Game titles and applications used
• Gaming session start and end times
• Task completion status
• Achievement and progress data

Account Information:
• Parent/guardian contact information
• Child's basic profile information (age, preferences)
• Account settings and preferences
• Device information and identifiers

2. HOW WE USE YOUR INFORMATION

We use collected information to:
• Provide gaming time monitoring services
• Generate reports for parents
• Implement parental controls and restrictions
• Improve our service functionality
• Ensure compliance with set limits and rules
• Facilitate task-based reward systems

3. INFORMATION SHARING

We do not sell, trade, or share your personal information with third parties except:
• With your explicit consent
• To comply with legal requirements
• To protect our rights and safety
• With trusted service providers who assist in app functionality

4. DATA SECURITY

We implement appropriate security measures to protect your information:
• Encryption of sensitive data
• Secure data transmission protocols
• Regular security audits and updates
• Limited access to personal information
• Secure data storage practices

5. CHILDREN'S PRIVACY

Special protections for children under 13:
• Parental consent required for all monitoring
• Limited data collection focused on gaming activities
• No behavioral profiling or targeted advertising
• Secure handling of all child-related data
• Right to request data deletion

6. DATA RETENTION

We retain your information for as long as:
• Your account remains active
• Required for service functionality
• Necessary for legal compliance
• Requested by parents for monitoring purposes

You may request data deletion at any time through your account settings.

7. YOUR RIGHTS

You have the right to:
• Access your personal information
• Correct inaccurate information
• Request deletion of your data
• Export your data
• Opt out of certain data processing
• Withdraw consent at any time

8. COOKIES AND TRACKING

We use cookies and similar technologies to:
• Maintain user sessions
• Remember user preferences
• Improve app performance
• Analyze usage patterns (anonymized)

9. THIRD-PARTY SERVICES

Our app may integrate with third-party services for:
• Game detection and monitoring
• Cloud data backup
• Analytics and performance monitoring

These services have their own privacy policies which we encourage you to review.

10. INTERNATIONAL DATA TRANSFERS

Your information may be transferred to and processed in countries other than your own. We ensure appropriate safeguards are in place for such transfers.

11. CHANGES TO THIS POLICY

We may update this privacy policy periodically. We will notify you of significant changes through the app or via email.

12. CONTACT US

For privacy-related questions or concerns:
• Use the in-app support feature
• Visit our website's privacy section
• Contact our data protection officer

13. PARENTAL CONTROLS AND CONSENT

• Parents have full control over their child's data
• Parental consent is required for all monitoring activities
• Parents can modify or delete their child's information at any time
• Children can request their parents to review or delete their data

By using iCtrl, you acknowledge that you have read and understood this Privacy Policy and consent to the collection and use of your information as described.
''';
  }
}