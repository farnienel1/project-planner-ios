# PowerShell script to enable SMTP authentication
# Run this: pwsh enable_smtp.ps1

# Connect to Exchange Online
Connect-ExchangeOnline

# Enable SMTP auth for your user
Set-CASMailbox -Identity "info@projectplanner.us" -SmtpClientAuthenticationDisabled $false

# Verify it worked
Write-Host "Checking SMTP auth status..." -ForegroundColor Yellow
$result = Get-CASMailbox -Identity "info@projectplanner.us" | Select SmtpClientAuthenticationDisabled
Write-Host "Current status: $($result.SmtpClientAuthenticationDisabled)" -ForegroundColor Cyan

if ($result.SmtpClientAuthenticationDisabled -eq $false) {
    Write-Host "✅ SMTP Authentication is ENABLED!" -ForegroundColor Green
} else {
    Write-Host "❌ SMTP Authentication is still DISABLED" -ForegroundColor Red
}

# Disconnect
Disconnect-ExchangeOnline

Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "1. Wait 10-15 minutes for changes to propagate"
Write-Host "2. Restart your backend"
Write-Host "3. Test email sending"
Write-Host ""











