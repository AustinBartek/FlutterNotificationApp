import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:device_preview/device_preview.dart';
import 'dart:async';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'dart:convert';
import 'package:timezone/timezone.dart';

class Reminder {
  final String title;
  final String content;
  final RecurringNotificationSettings settings;
  final int? id;

  const Reminder({
    this.id,
    required this.title,
    required this.content,
    required this.settings,
  });

  Map<String, Object?> toMap() {
    return {
      'title': title,
      'content': content,
      'recurSettings': settings.serialize(),
    };
  }

  @override
  String toString() {
    return 'Favorite{id: $id, title: $title, content: $content}';
  }
}

class RecurringNotificationSettings {
  final List<double> times;

  const RecurringNotificationSettings({required this.times});

  String serialize() {
    return jsonEncode({'times': times});
  }

  static RecurringNotificationSettings deserialize(String serialized) {
    Map data = jsonDecode(serialized);
    List<double> times = data['times'];
    return RecurringNotificationSettings(times: times);
  }
}

class DatabaseManager {
  static Database? database;

  static Future<void> init() async {
    database = await openDatabase(
      // Set the path to the database. Note: Using the `join` function from the
      // `path` package is best practice to ensure the path is correctly constructed for each platform.
      join(await getDatabasesPath(), 'reminder_database.db'),

      onCreate: (db, version) {
        return db.execute(
          "CREATE TABLE reminders(id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT, content TEXT, recurSettings TEXT)",
        );
      },

      version: 1,
    );
  }

  static Future<void> insertReminder(Reminder reminder) async {
    NotificationManager.addRecurringNotification(reminder);
    final db = database!;

    await db.insert(
      'reminders',
      reminder.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<void> updateReminder(Reminder reminder) async {
    NotificationManager.updateRecurringNotifications(reminder);
    final db = database!;

    await db.update(
      'reminders',
      reminder.toMap(),
      where: 'id = ?',
      whereArgs: [reminder.id],
    );
  }

  static Future<List<Reminder>> getReminders() async {
    final db = database!;
    final maps = await db.query('reminders');

    return maps.map((row) {
      final String title = row['title'] as String;
      final String content = row['content'] as String;
      final int id = row['id'] as int;
      final RecurringNotificationSettings recurSettings =
          RecurringNotificationSettings.deserialize(
            row['recurSettings'] as String,
          );
      return Reminder(
        id: id,
        title: title,
        content: content,
        settings: recurSettings,
      );
    }).toList();
  }

  static Future<void> deleteReminder(Reminder reminder) async {
    NotificationManager.removeRecurringNotification(reminder);
    final db = database!;
    await db.delete('reminders', where: 'id = ?', whereArgs: [reminder.id]);
  }
}

class NotificationManager {
  static final int _reminderSlotSize = 1000;
  static final FlutterLocalNotificationsPlugin notifications =
      FlutterLocalNotificationsPlugin();

  static Future<void> init() async {
    tz.initializeTimeZones();

    const initializationSettingsIOS = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const initializationSettings = InitializationSettings(
      iOS: initializationSettingsIOS,
    );

    await notifications.initialize(initializationSettings);
  }

  static Future<void> addRecurringNotification(Reminder reminder) async {
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentSound: true,
    );

    const details = NotificationDetails(iOS: iosDetails);

    final location = getLocation("America/Chicago");
    final now = TZDateTime.now(location);

    int slotCount = 0;
    for (double time in reminder.settings.times) {
      int hours = time.floor();
      int mins = ((time - time.floor()) * 60) as int;
      var scheduled = TZDateTime(
        location,
        now.year,
        now.month,
        now.day,
        hours,
        mins,
      );

      if (scheduled.isBefore(now)) {
        scheduled = scheduled.add(const Duration(days: 1));
      }

      int useId = _calcReminderId(reminder, slotCount);
      slotCount++;

      await notifications.zonedSchedule(
        useId,
        reminder.title,
        reminder.content,
        scheduled,
        details,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents: DateTimeComponents.time,
      );
    }
  }

  static Future<void> removeRecurringNotification(Reminder reminder) async {
    int base = reminder.id! * _reminderSlotSize;
    for (int i = 0; i < _reminderSlotSize; i++) {
      int useId = base + i;
      await notifications.cancel(useId);
    }
  }

  static Future<void> updateRecurringNotifications(Reminder reminder) async {
    removeRecurringNotification(reminder);
    addRecurringNotification(reminder);
  }

  static int _calcReminderId(Reminder reminder, int slot) {
    return reminder.id! * _reminderSlotSize + slot;
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // REQUIRED for desktop
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  await DatabaseManager.init();
  await NotificationManager.init();

  runApp(DevicePreview(builder: (context) => MyApp()));
  //runApp(MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (context) => MyAppState(),
      child: MaterialApp(
        title: 'Names App',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color.fromARGB(255, 69, 85, 255),
          ),
        ),
        home: MyHomePage(),
      ),
    );
  }
}

class MyAppState extends ChangeNotifier {
  // Load the reminders on initialization
  MyAppState() {
    loadReminders();
  }

  var reminders = <Reminder>[];

  Future<void> loadReminders() async {
    reminders = await DatabaseManager.getReminders();
    notifyListeners();
  }

  Future<void> addReminder(Reminder reminder) async {
    await DatabaseManager.insertReminder(reminder);
    await loadReminders();
  }

  Future<void> updateReminder(Reminder reminder) async {
    await DatabaseManager.updateReminder(reminder);
    await loadReminders();
  }

  Future<void> deleteReminder(Reminder reminder) async {
    await DatabaseManager.deleteReminder(reminder);
    await loadReminders();
  }

  int _pageNum = 0;
  int get pageNum => _pageNum;

  void setPage(int page) {
    _pageNum = page;
    notifyListeners();
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  @override
  Widget build(BuildContext context) {
    var theme = Theme.of(context);
    var appState = context.watch<MyAppState>();

    Widget page;
    switch (appState.pageNum) {
      case 0:
        page = ReminderPage();
        break;
      case 1:
        page = ReminderCreationPage();
        break;
      default:
        throw UnimplementedError('no widget for ${appState.pageNum}');
    }

    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: Container(
              color: theme.colorScheme.secondaryContainer,
              child: page,
            ),
          ),

          BottomNavigationBar(
            items: [
              BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
              BottomNavigationBarItem(
                icon: Icon(Icons.add),
                label: 'New Reminder',
              ),
            ],
            currentIndex: appState.pageNum,
            onTap: (value) {
              setState(() {
                appState.setPage(value);
              });
            },
          ),
        ],
      ),
    );
  }
}

class ReminderPage extends StatelessWidget {
  const ReminderPage({super.key});

  @override
  Widget build(BuildContext context) {
    var appState = context.watch<MyAppState>();
    var reminders = appState.reminders;
    var theme = Theme.of(context);

    return Center(
      child: ListView(
        children: [
          Text("Reminders", style: theme.textTheme.displayLarge),
          for (Reminder rem in reminders) ReminderCard(reminder: rem),
        ],
      ),
    );
  }
}

class ReminderCard extends StatelessWidget {
  const ReminderCard({super.key, required this.reminder});

  final Reminder reminder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bigStyle = theme.textTheme.displaySmall!.copyWith(
      color: theme.colorScheme.onSecondary,
    );
    final style = theme.textTheme.bodyLarge!.copyWith(
      color: theme.colorScheme.onPrimary,
    );

    return Card(
      color: theme.colorScheme.primary,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Text(reminder.title, style: bigStyle, maxLines: 1),
            Text(
              reminder.content,
              style: style,
              overflow: TextOverflow.ellipsis,
              maxLines: 3,
            ),
          ],
        ),
      ),
    );
  }
}

class ReminderCreationPage extends StatefulWidget {
  const ReminderCreationPage({super.key});

  @override
  State<ReminderCreationPage> createState() => _ReminderCreationPageState();
}

class _ReminderCreationPageState extends State<ReminderCreationPage> {
  final titleTextController = TextEditingController();
  final contentTextController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<MyAppState>();
    final theme = Theme.of(context);

    final titleInput = TextField(
      decoration: InputDecoration(
        labelText: "Reminder Title",
        filled: true,
        fillColor: theme.colorScheme.surfaceContainer,
      ),
      autocorrect: true,
      controller: titleTextController,
    );
    final contentInput = TextField(
      decoration: InputDecoration(
        labelText: "Reminder Content",
        filled: true,
        fillColor: theme.colorScheme.surfaceContainer,
      ),
      autocorrect: true,
      minLines: 5,
      maxLines: 10,
      controller: contentTextController,
    );
    final addButton = ElevatedButton(
      onPressed: () async {
        final title = titleTextController.text;
        final content = contentTextController.text;

        if (title.isEmpty || content.isEmpty) {
          showDialog(
            context: context,
            builder: (context) {
              return AlertDialog(content: Text("Please fill out every field!"));
            },
          );
          return;
        }

        final RecurringNotificationSettings recurSettings =
            RecurringNotificationSettings(times: [12, 22.8, 22.85, 22.9, 22.95, 22.99, 23.05, 23.1, 23.12, 23.15]);

        Reminder reminderToAdd = Reminder(
          title: title,
          content: content,
          settings: recurSettings,
        );
        await appState.addReminder(reminderToAdd);
        appState.setPage(0); //Go back to home page
      },
      child: Text("Create Reminder"),
    );

    return SafeArea(
      bottom: false,
      child: Expanded(
        child: Container(
          color: theme.colorScheme.secondaryContainer,
          child: Column(children: [titleInput, contentInput, addButton]),
        ),
      ),
    );
  }
}
