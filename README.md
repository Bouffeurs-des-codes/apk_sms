# Paiements scolaires

L’application Flutter pour Android enregistre les élèves et les paiements en francs
congolais. Le serveur conserve les reçus dans SQLite. L’application envoie la
confirmation depuis la SIM Airtel active du téléphone Android.

## Essai sur Android

Dans un terminal PowerShell, démarrez le serveur Python 3.

```powershell
$env:SCHOOL_API_KEY = 'essai-local'
python server/app.py
```

Dans un autre terminal, utilisez l’identifiant du téléphone indiqué par
`flutter devices`. Exemple pour un téléphone connecté en Wi-Fi.

```powershell
$adb = "$env:LOCALAPPDATA\Android\sdk\platform-tools\adb.exe"
& $adb -s 192.168.0.181:5555 reverse tcp:8080 tcp:8080
flutter run -d 192.168.0.181:5555
```

Saisissez le mot de passe du serveur. Au premier paiement, autorisez Android à
détecter les SIM et à envoyer des SMS. Utilisez un numéro que vous contrôlez
pour un essai. L’envoi utilise le crédit ou le forfait Airtel. Le destinataire
voit le numéro de la SIM comme expéditeur.

« SMS confié à Android via Airtel » signifie que la demande a été transmise
au système. Vérifiez la réception sur le téléphone destinataire. Les anciens
reçus restent dans l’historique et ne déclenchent aucun envoi.

En production, utilisez un proxy HTTPS, un mot de passe fort et
`--dart-define=SCHOOL_URL=https://votre-serveur`. La variable SCHOOL_DB
permet de choisir un emplacement hors du dépôt pour la base SQLite.
