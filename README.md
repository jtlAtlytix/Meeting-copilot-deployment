# 🚀 AI Meeting Copilot  
## Install, Validate & Test Guide  
**External Tenant · Zero Permissions · Production-ready**

Denne guide beskriver hele processen fra **0 → live løsning** i en ekstern Microsoft 365 / Azure tenant, hvor **ingen rettigheder er givet på forhånd**.

Guiden kan bruges af:
- Atlytix (intern deployment)
- Kundens IT / Azure Admin
- Ekstern partner / MSP


## FORUDSÆTNINGER & RETTIGHEDER

### Azure / Entra ID
Deployment kræver én af følgende:

**Anbefalet (nemmest):**
- Global Administrator

**Alternativt:**
- Application Administrator  
- Cloud Application Administrator  
- Contributor på Subscription eller Resource Group  

Hvis der oprettes ny Resource Group, kræves rettigheder på Subscription-niveau.


### Microsoft Teams
Efter deployment kræves:
- Teams Administrator
- Adgang til MicrosoftTeams PowerShell


## INSTALLATION (DEPLOYMENT)

### Forberedelse
1. Download eller clone deploy-pakken
2. Åbn PowerShell x64
3. (Valgfrit) Kør som Administrator


### Login til Azure

```powershell
az login
```

- Log ind med kundens Azure-konto  
- Bekræft korrekt tenant, hvis du har adgang til flere


### Kør deploy-script

```powershell
.\scripts\deploy.ps1 `
  -SetupEntra `
  -UseExistingResourceGroup `
  -PackageUrl "https://atlytixmcprelprod.blob.core.windows.net/releases/meetingcopilot-function-1.1.8.zip?se=2027-02-02T14%3A17Z&sp=r&sv=2022-11-02&sr=b&sig=bBRppxtWNcMNTmr5slDu95iKapGPfr426PvsQzqEn1w%3D"
```

PackageUrl peger på den færdigbyggede Function App-pakke, som Azure automatisk henter via WEBSITE_RUN_FROM_PACKAGE.


### Interaktiv konfiguration

Scriptet vil nu stille en række spørgsmål:

**Customer Code**  
Fx: `testtest123`  
Bruges til app-navne og ressourcer.

**Azure Region**  
Typisk: `westeurope`

**Resource Group**  
Vælg eksisterende (anbefalet) eller opret ny.

**Mail Sender (krævet)**  
Fx: `automate@kundedomain.dk`  
Skal være fra kundens tenant.

**OpenAI API Key (valgfri)**  
Kan tilføjes nu eller senere.

**Licensing API Key (påkrævet)**  
Udstedes via https://nice-moss-084be6303.3.azurestaticapps.net


### Deployment færdig

Når scriptet er færdigt, vises bl.a.:

```
Admin consent URL:
https://login.microsoftonline.com/{tenant}/adminconsent?client_id=...
```


## ADMIN CONSENT

1. Send Admin Consent URL til Global Admin  
2. Global Admin åbner linket  
3. Godkend permissions  

Dette giver appen adgang til:
- Teams meeting transcripts
- Online meetings
- Meeting metadata
- Afsendelse af mails


## TEAMS APPLICATION ACCESS POLICY

Connect til Teams:

```powershell
Install-Module MicrosoftTeams -Force
Connect-MicrosoftTeams
```

Opret policy:

```powershell
New-CsApplicationAccessPolicy `
  -Identity "Tag:AI-Meeting-Copilot-Access" `
  -AppIds "APP_ID_FRA_APP_REGISTRATION" `
  -Description "AI Meeting Copilot transcript access"
```

Tildel policy globalt:

```powershell
Grant-CsApplicationAccessPolicy `
  -PolicyName "AI-Meeting-Copilot-Access" `
  -Global
```

Verificér:

```powershell
Get-CsApplicationAccessPolicy `
  -Identity "Tag:AI-Meeting-Copilot-Access" | Format-List
```


## VALIDATE & END-TO-END TEST

### Tjek Environment Variables
Azure Portal → Function App → Settings → Configuration

Kontrollér bl.a.:
- TENANT_ID
- CLIENT_ID
- CLIENT_SECRET
- MAIL_SENDER_UPN
- LICENSING_API_KEY
- OPENAI_API_KEY (hvis brugt)

Gem ændringer om nødvendigt.


### Log Stream
Function App → Monitoring → Log stream  
Lad log stream være åben under testen.


### Start testmøde
1. Start et Teams-møde  
2. Start Live Transcription  
3. Brug meeting organizer eller transcription-starter


### Forventet resultat
- Organizer modtager mail med editor-link  
- Editor kan redigere resume og sende mails  

Flowet er bekræftet:
Teams → Graph → Azure → AI → Editor → Mail


### Fejlsøgning
Tjek Log Stream for:
- Manglende permissions
- Licensing-fejl
- Manglende environment variables

Hvis problemet ikke kan løses:
Kontakt jtl@atlytix.dk  
Vedhæft log-output og customer code.


## KLAR TIL PRODUKTION

Når alle steps er gennemført:
- Løsningen er live
- Kunden er klar til brug
- Setup kan gentages 1:1 hos næste kunde
