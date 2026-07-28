// Copyright (c) 2026 Your Company/Name.
// Licensed under the MIT License — see LICENSE for details.

enum DetectionType { sound, motion }

class DetectionEvent {
  final DetectionType type;
  final DateTime time;

  DetectionEvent(this.type) : time = DateTime.now();

  Map<String, dynamic> toJson() => {
        'kind': 'detection',
        'detectionType': type.name,
        'time': time.toIso8601String(),
      };

  static DetectionEvent? fromJson(Map<String, dynamic> json) {
    if (json['kind'] != 'detection') return null;
    final t = json['detectionType'] == 'sound'
        ? DetectionType.sound
        : json['detectionType'] == 'motion'
            ? DetectionType.motion
            : null;
    if (t == null) return null;
    return DetectionEvent(t);
  }

  String get label => type == DetectionType.sound ? 'Sound detected' : 'Motion detected';
}
