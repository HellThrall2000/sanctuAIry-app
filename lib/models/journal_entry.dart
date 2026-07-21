class JournalEntry {
  final String id;
  final String title;
  final String content;
  final String date;
  final bool allowAiAccess;

  JournalEntry({
    required this.id,
    required this.title,
    required this.content,
    required this.date,
    required this.allowAiAccess,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'content': content,
      'date': date,
      'allowAiAccess': allowAiAccess ? 1 : 0,
    };
  }

  factory JournalEntry.fromMap(Map<String, dynamic> map) {
    return JournalEntry(
      id: map['id'] as String,
      title: map['title'] as String,
      content: map['content'] as String,
      date: map['date'] as String,
      allowAiAccess: (map['allowAiAccess'] as int) == 1,
    );
  }

  JournalEntry copyWith({
    String? id,
    String? title,
    String? content,
    String? date,
    bool? allowAiAccess,
  }) {
    return JournalEntry(
      id: id ?? this.id,
      title: title ?? this.title,
      content: content ?? this.content,
      date: date ?? this.date,
      allowAiAccess: allowAiAccess ?? this.allowAiAccess,
    );
  }
}
