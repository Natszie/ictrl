import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Add Schedule Dialog Widget
class _AddScheduleDialog extends StatefulWidget {
  final List<Map<String, dynamic>> pairedDevices;
  final Function(Map<String, dynamic>) onScheduleAdded;

  const _AddScheduleDialog({
    required this.pairedDevices,
    required this.onScheduleAdded,
  });

  @override
  _AddScheduleDialogState createState() => _AddScheduleDialogState();
}

class _AddScheduleDialogState extends State<_AddScheduleDialog> {
  final _formKey = GlobalKey<FormState>();
  final _gameNameController = TextEditingController();
  final _descriptionController = TextEditingController();

  String? _selectedChildDeviceId;
  DateTime _selectedDate = DateTime.now();
  TimeOfDay _startTime = TimeOfDay.now();
  TimeOfDay _endTime = TimeOfDay(hour: TimeOfDay.now().hour + 1, minute: TimeOfDay.now().minute);
  bool _isRecurring = false;
  List<int> _selectedDays = [];

  final List<String> _dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  @override
  void dispose() {
    _gameNameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  int _calculateDuration() {
    final start = DateTime(2024, 1, 1, _startTime.hour, _startTime.minute);
    final end = DateTime(2024, 1, 1, _endTime.hour, _endTime.minute);
    final duration = end.difference(start);
    return duration.inMinutes > 0 ? duration.inMinutes : duration.inMinutes + 1440; // Handle next day
  }

  String _getChildDeviceName(String childDeviceId) {
    try {
      final pairedDevice = widget.pairedDevices.firstWhere(
            (device) => device['childDeviceId'] == childDeviceId,
      );

      final childDeviceInfo = pairedDevice['childDeviceInfo'] as Map<String, dynamic>? ?? {};
      final deviceBrand = childDeviceInfo['brand'] ?? 'Unknown';
      final deviceModel = childDeviceInfo['device'] ?? 'Device';
      return '$deviceBrand $deviceModel';
    } catch (e) {
      return 'Unknown Device';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF2D3748),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        padding: const EdgeInsets.all(24),
        constraints: const BoxConstraints(maxWidth: 400, maxHeight: 600),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Add Gaming Schedule',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, color: Colors.white),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Child Device Selection
                      const Text(
                        'Select Child Device',
                        style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF4A5568),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: _selectedChildDeviceId,
                            hint: const Text('Choose a device', style: TextStyle(color: Colors.grey)),
                            dropdownColor: const Color(0xFF4A5568),
                            style: const TextStyle(color: Colors.white),
                            isExpanded: true,
                            items: widget.pairedDevices.map((device) {
                              final childDeviceId = device['childDeviceId'];
                              return DropdownMenuItem<String>(
                                value: childDeviceId,
                                child: Text(_getChildDeviceName(childDeviceId)),
                              );
                            }).toList(),
                            onChanged: (value) => setState(() => _selectedChildDeviceId = value),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Game Name
                      const Text(
                        'Game/App Name',
                        style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _gameNameController,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: 'Enter game or app name',
                          hintStyle: TextStyle(color: Colors.grey[400]),
                          filled: true,
                          fillColor: const Color(0xFF4A5568),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        validator: (value) => value?.isEmpty == true ? 'Game name is required' : null,
                      ),
                      const SizedBox(height: 16),

                      // Date Selection
                      const Text(
                        'Schedule Date',
                        style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 8),
                      InkWell(
                        onTap: () async {
                          final date = await showDatePicker(
                            context: context,
                            initialDate: _selectedDate,
                            firstDate: DateTime.now(),
                            lastDate: DateTime.now().add(const Duration(days: 365)),
                            builder: (context, child) {
                              return Theme(
                                data: Theme.of(context).copyWith(
                                  colorScheme: const ColorScheme.dark(
                                    primary: Color(0xFFE07A39),
                                    surface: Color(0xFF2D3748),
                                  ),
                                ),
                                child: child!,
                              );
                            },
                          );
                          if (date != null) setState(() => _selectedDate = date);
                        },
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF4A5568),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                '${_selectedDate.day}/${_selectedDate.month}/${_selectedDate.year}',
                                style: const TextStyle(color: Colors.white),
                              ),
                              const Icon(Icons.calendar_today, color: Color(0xFFE07A39)),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Time Selection
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Start Time',
                                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
                                ),
                                const SizedBox(height: 8),
                                InkWell(
                                  onTap: () async {
                                    final time = await showTimePicker(
                                      context: context,
                                      initialTime: _startTime,
                                      builder: (context, child) {
                                        return Theme(
                                          data: Theme.of(context).copyWith(
                                            colorScheme: const ColorScheme.dark(
                                              primary: Color(0xFFE07A39),
                                              surface: Color(0xFF2D3748),
                                            ),
                                          ),
                                          child: child!,
                                        );
                                      },
                                    );
                                    if (time != null) setState(() => _startTime = time);
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF4A5568),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(
                                          _startTime.format(context),
                                          style: const TextStyle(color: Colors.white),
                                        ),
                                        const Icon(Icons.access_time, color: Color(0xFFE07A39)),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'End Time',
                                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
                                ),
                                const SizedBox(height: 8),
                                InkWell(
                                  onTap: () async {
                                    final time = await showTimePicker(
                                      context: context,
                                      initialTime: _endTime,
                                      builder: (context, child) {
                                        return Theme(
                                          data: Theme.of(context).copyWith(
                                            colorScheme: const ColorScheme.dark(
                                              primary: Color(0xFFE07A39),
                                              surface: Color(0xFF2D3748),
                                            ),
                                          ),
                                          child: child!,
                                        );
                                      },
                                    );
                                    if (time != null) setState(() => _endTime = time);
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF4A5568),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(
                                          _endTime.format(context),
                                          style: const TextStyle(color: Colors.white),
                                        ),
                                        const Icon(Icons.access_time, color: Color(0xFFE07A39)),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // Duration Display
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE07A39).withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFFE07A39).withOpacity(0.3)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.timer, color: Color(0xFFE07A39), size: 20),
                            const SizedBox(width: 8),
                            Text(
                              'Duration: ${_calculateDuration()} minutes',
                              style: const TextStyle(color: Color(0xFFE07A39), fontWeight: FontWeight.w500),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Description (Optional)
                      const Text(
                        'Description (Optional)',
                        style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _descriptionController,
                        style: const TextStyle(color: Colors.white),
                        maxLines: 3,
                        decoration: InputDecoration(
                          hintText: 'Add any additional notes...',
                          hintStyle: TextStyle(color: Colors.grey[400]),
                          filled: true,
                          fillColor: const Color(0xFF4A5568),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                    ],
                  ),
                ),
              ),

              // Action Buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text(
                      'Cancel',
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton(
                    onPressed: () {
                      if (_formKey.currentState!.validate() && _selectedChildDeviceId != null) {
                        widget.onScheduleAdded({
                          'childDeviceId': _selectedChildDeviceId,
                          'gameName': _gameNameController.text.trim(),
                          'scheduledDate': _selectedDate,
                          'startTime': _startTime,
                          'endTime': _endTime,
                          'durationMinutes': _calculateDuration(),
                          'description': _descriptionController.text.trim(),
                          'isRecurring': _isRecurring,
                          'recurringDays': _selectedDays,
                        });
                        Navigator.pop(context);
                      } else if (_selectedChildDeviceId == null) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Please select a child device')),
                        );
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFE07A39),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: const Text('Add Schedule'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}