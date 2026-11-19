import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

void main() => runApp(const MyApp());

const server = String.fromEnvironment(
  'SCHOOL_URL',
  defaultValue: 'http://127.0.0.1:8080',
);

typedef Record = Map<String, dynamic>;

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Paiements scolaires',
    theme: ThemeData(colorSchemeSeed: const Color(0xff166455)),
    home: const SchoolPage(),
  );
}

class SchoolPage extends StatefulWidget {
  const SchoolPage({super.key});

  @override
  State<SchoolPage> createState() => _SchoolPageState();
}

class _SchoolPageState extends State<SchoolPage> {
  static const airtel = MethodChannel('school/airtel');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  final key = TextEditingController();
  final name = TextEditingController();
  final phone = TextEditingController();
  final amount = TextEditingController();
  List<Record> students = [];
  List<Record> payments = [];
  Record? pendingPayment;
  String? feeType;
  static const feeLabels = {
    'minerval': 'Minerval',
    'tuition': 'Scolarité',
    'state': 'Frais de l’État',
  };
  int? selected;
  bool connected = false;
  bool passwordVisible = false;
  bool busy = false;

  Future<Record> request(String path, [Record? data]) async {
    final uri = Uri.parse('$server/$path');
    if (uri.scheme != 'https' &&
        !(uri.scheme == 'http' && uri.host == '127.0.0.1')) {
      throw const FormatException(
        'Utilisez une adresse HTTPS pour le serveur.',
      );
    }
    final request = await client.openUrl(data == null ? 'GET' : 'POST', uri);
    request.followRedirects = false;
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${key.text.trim()}',
    );
    if (data != null) {
      final body = utf8.encode(jsonEncode(data));
      request.headers.contentType = ContentType.json;
      request.contentLength = body.length;
      request.add(body);
    }
    final response = await request.close().timeout(const Duration(seconds: 35));
    final result =
        jsonDecode(await response.transform(utf8.decoder).join()) as Record;
    if (response.statusCode == 401) {
      throw const FormatException('Mot de passe incorrect.');
    }
    if (response.statusCode != 200) {
      throw FormatException(result['error'] as String? ?? 'Erreur du serveur.');
    }
    return result;
  }

  Future<void> refresh() async {
    final results = await Future.wait([
      request('students'),
      request('payments'),
    ]);
    if (!mounted) return;
    setState(() {
      students = (results[0]['items'] as List).cast<Record>();
      payments = (results[1]['items'] as List).cast<Record>();
      connected = true;
    });
  }

  void notice(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> run(Future<void> Function() operation) async {
    if (busy) return;
    FocusScope.of(context).unfocus();
    setState(() => busy = true);
    try {
      await operation();
    } on FormatException catch (error) {
      notice(error.message);
    } catch (_) {
      notice('Serveur injoignable. Vérifiez la connexion et réessayez.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> addStudent() async {
    final number = phone.text.replaceAll(RegExp(r'[\s()-]'), '');
    await request('students', {
      'name': name.text.trim(),
      'phone': number.startsWith('0') ? '+243${number.substring(1)}' : number,
    });
    if (!mounted) return;
    name.clear();
    phone.clear();
    notice('Élève enregistré.');
    await refresh();
  }

  Future<void> addPayment() async {
    if (feeType == null) {
      throw const FormatException('Choisissez un type de frais.');
    }
    final value = int.tryParse(amount.text.trim());
    if (selected == null ||
        value == null ||
        value <= 0 ||
        value > 1000000000000) {
      throw const FormatException(
        'Choisissez un élève et saisissez un montant valide en FC.',
      );
    }
    final random = Random.secure();
    pendingPayment ??= {
      'student_id': selected,
      'amount': value,
      'fee_type': feeType,
      'request_id': List.generate(
        16,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join(),
    };
    final payment = await request('payments', pendingPayment);
    pendingPayment = null;
    if (!mounted) return;
    amount.clear();
    final phone = payment['phone'];
    if (phone is String) {
      var status = 'airtel_failed';
      try {
        status = await airtel.invokeMethod<String>('send', {
          'phone': phone,
          'message': 'Paiement reçu pour ${payment['name']}. '
              'Type de frais : ${feeLabel(payment)}. '
              'Montant : ${formatAmount(payment['amount'] as int)} FC. '
              'Reçu n° ${receipt(payment)}.',
        }) ?? status;
      } on PlatformException {
        // The receipt remains valid if Android cannot submit the SMS.
      } on MissingPluginException {
        // Sending via SIM is available on Android.
      }
      payment['sms'] = status;
      notice('Reçu n° ${receipt(payment)} · ${smsStatus(payment)}');
      await request('payments/sms', {
        'request_id': payment['request_id'],
        'status': status,
      });
    } else {
      notice('Reçu n° ${receipt(payment)} · ${smsStatus(payment)}');
    }
    await refresh();
  }

  String receipt(Record payment) => payment['id'].toString().padLeft(6, '0');

  String feeLabel(Record payment) =>
      feeLabels[payment['fee_type']] ?? 'Type de frais non renseigné';

  String formatAmount(int value) => value.toString().replaceAllMapped(
    RegExp(r'\d(?=(\d{3})+$)'),
    (match) => '${match[0]} ',
  );

  String smsStatus(Record payment) => switch (payment['sms']) {
    'airtel_submitted' => 'SMS confié à Android via Airtel',
    'airtel_no_sim' => 'SIM Airtel active introuvable',
    'airtel_permission' => 'Autorisations SMS ou téléphone refusées',
    'airtel_failed' => 'Échec de la demande SMS Airtel',
    'accepted' => 'SMS accepté par Orange',
    'unconfigured' => 'Service SMS non configuré',
    'failed' => 'Échec SMS',
    _ => 'SMS à vérifier',
  };

  @override
  void dispose() {
    client.close(force: true);
    for (final controller in [key, name, phone, amount]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Paiements scolaires'),
      actions: [
        if (connected)
          IconButton(
            onPressed: busy ? null : () => run(refresh),
            tooltip: 'Actualiser',
            icon: const Icon(Icons.refresh),
          ),
      ],
    ),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              if (busy) const LinearProgressIndicator(),
              if (!connected) ...[
                TextField(
                  controller: key,
                  obscureText: !passwordVisible,
                  enabled: !busy,
                  autocorrect: false,
                  enableSuggestions: false,
                  onSubmitted: (_) => run(refresh),
                  decoration: InputDecoration(
                    labelText: 'Mot de passe',
                    suffixIcon: IconButton(
                      tooltip: passwordVisible
                          ? 'Masquer le mot de passe'
                          : 'Afficher le mot de passe',
                      onPressed: () => setState(
                        () => passwordVisible = !passwordVisible,
                      ),
                      icon: Icon(
                        passwordVisible ? Icons.visibility_off : Icons.visibility,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: busy ? null : () => run(refresh),
                  child: const Text('Se connecter'),
                ),
              ] else ...[
                section('Nouvel élève'),
                TextField(
                  controller: name,
                  enabled: !busy,
                  decoration: const InputDecoration(
                    labelText: 'Nom de l’élève',
                  ),
                ),
                TextField(
                  controller: phone,
                  enabled: !busy,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Téléphone du parent',
                    hintText: '+243…',
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: busy ? null : () => run(addStudent),
                  child: const Text('Enregistrer l’élève'),
                ),
                const Divider(height: 36),
                section('Nouveau paiement'),
                if (students.isEmpty)
                  const Text('Ajoutez un élève pour enregistrer un paiement.'),
                if (students.isNotEmpty)
                  DropdownButtonFormField<int>(
                    initialValue: selected,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Élève'),
                    items: students
                        .map(
                          (student) => DropdownMenuItem<int>(
                            value: student['id'] as int,
                            child: Text(
                              "${student['name']} · ${student['phone']}",
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: busy || pendingPayment != null
                        ? null
                        : (id) {
                            setState(() => selected = id);
                          },
                  ),
                DropdownButtonFormField<String>(
                  initialValue: feeType,
                  decoration: const InputDecoration(labelText: 'Type de frais'),
                  items: [
                    for (final fee in feeLabels.entries)
                      DropdownMenuItem(value: fee.key, child: Text(fee.value)),
                  ],
                  onChanged: busy || pendingPayment != null
                      ? null
                      : (value) => setState(() => feeType = value),
                ),
                TextField(
                  controller: amount,
                  enabled: !busy && selected != null && pendingPayment == null,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Montant en FC'),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: busy || selected == null
                      ? null
                      : () => run(addPayment),
                  child: Text(
                    pendingPayment == null
                        ? 'Valider le paiement'
                        : 'Réessayer',
                  ),
                ),
                const Divider(height: 36),
                section('Historique'),
                if (payments.isEmpty) const Text('Aucun paiement enregistré.'),
                for (final payment in payments)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.receipt_long_outlined),
                    title: Text("${payment['name']} · ${payment['amount']} FC"),
                    subtitle: Text(
                      '${feeLabel(payment)}\n'
                      'Reçu n° ${receipt(payment)} · ${smsStatus(payment)}',
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    ),
  );

  Widget section(String title) =>
      Text(title, style: Theme.of(context).textTheme.titleLarge);
}
