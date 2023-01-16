[CmdletBinding()]
param()

$saName = 'sa-xinetd-updater'
$token = kubectl create token $saName

./Update-XinetdConfig.ps1 `
    -ApiServerUrl 'https://localhost:16443' `
    -AccessToken $token `
    -ConfigFilePath "xinetd.config.txt" `
    -ForwardLoadBalancer `
    -ForwardNodePort