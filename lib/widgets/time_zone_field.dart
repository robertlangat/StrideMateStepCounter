import 'package:flutter/material.dart';

const commonTimeZones = [
  'UTC', 'Africa/Nairobi', 'Africa/Lagos', 'Africa/Cairo', 'Africa/Johannesburg', 'Africa/Accra',
  'Europe/London', 'Europe/Dublin', 'Europe/Lisbon', 'Europe/Paris', 'Europe/Berlin', 'Europe/Madrid',
  'Europe/Rome', 'Europe/Amsterdam', 'Europe/Stockholm', 'Europe/Warsaw', 'Europe/Athens', 'Europe/Istanbul',
  'Europe/Moscow', 'Asia/Dubai', 'Asia/Karachi', 'Asia/Kolkata', 'Asia/Dhaka', 'Asia/Bangkok', 'Asia/Jakarta',
  'Asia/Singapore', 'Asia/Manila', 'Asia/Shanghai', 'Asia/Hong_Kong', 'Asia/Seoul', 'Asia/Tokyo',
  'Australia/Perth', 'Australia/Sydney', 'Pacific/Auckland', 'America/St_Johns', 'America/Halifax',
  'America/New_York', 'America/Chicago', 'America/Denver', 'America/Phoenix', 'America/Los_Angeles',
  'America/Anchorage', 'Pacific/Honolulu', 'America/Mexico_City', 'America/Bogota', 'America/Lima',
  'America/Sao_Paulo', 'America/Argentina/Buenos_Aires', 'America/Santiago',
];

/// Picks an IANA time zone; the server validates the final value.
class TimeZoneField extends StatelessWidget {
  const TimeZoneField({super.key, required this.value, required this.deviceZone, required this.onChanged});
  final String value;
  final String deviceZone;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final zones = {deviceZone, value, ...commonTimeZones}.toList();
    return DropdownButtonFormField<String>(
      value: value,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Time zone',
        helperText: 'Everyone is scored on this zone\'s midnight.',
        border: OutlineInputBorder(),
      ),
      items: [
        for (final z in zones)
          DropdownMenuItem(value: z, child: Text(z == deviceZone ? '$z (this device)' : z)),
      ],
      onChanged: (z) {
        if (z != null) onChanged(z);
      },
    );
  }
}
