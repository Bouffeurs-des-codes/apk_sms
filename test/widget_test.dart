import 'package:apk_sms/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Le formulaire de connexion est affiché', (tester) async {
    await tester.pumpWidget(const MyApp());
    expect(find.text('Paiements scolaires'), findsOneWidget);
    expect(find.text('Mot de passe'), findsOneWidget);
    await tester.tap(find.byTooltip('Afficher le mot de passe'));
    await tester.pump();
    expect(find.byTooltip('Masquer le mot de passe'), findsOneWidget);
    expect(find.text('Se connecter'), findsOneWidget);
  });
}
