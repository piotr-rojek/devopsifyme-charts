[CmdletBinding()]
param(
    $ApiServerUrl = 'https://kubernetes.default.svc',
    $AccessToken = (Get-Content '/var/run/secrets/kubernetes.io/serviceaccount/token'),
    $ConfigFilePath = '/etc/xinetd.d/k8s',

    [Switch]$ForwardNodePort = $true,
    [Switch]$ForwardLoadBalancer = $true,
    [Switch]$RunCommandsOnHost = $true
)

function Get-K8sServices
{
    $apiurl = "$($ApiServerUrl)/api/v1/services?limit=500"
    $k8sheader = @{authorization="Bearer $($AccessToken)"}
    $services = Invoke-RestMethod -Method GET -Uri $apiurl -Headers $k8sheader -SkipCertificateCheck
    return $services
}

function Handle-Service($srv)
{
    foreach($port in $srv.spec.ports)
    {
        Handle-Port -srv $srv -port $port
    }
}

function Handle-Port($srv, $port)
{
    # we support only TCP ports
    if($port.protocol -ne 'TCP')
    {
        Write-Warning "$($srv.metadata.name):$($port.port) not supported protocol $($port.protocol)"
        return
    }

    # forwward LoadBalancer port
    if($ForwardLoadBalancer -and $srv.spec.type -eq "LoadBalancer") 
    {
        Write-Host "$($srv.metadata.name):$($port.port) registered port $($port.port) forwarding to 127.0.0.1"
        #if load balancer IP is not assigned, use node port
        $address = $srv.status.loadBalancer.ingress.ip ?? "127.0.0.1"
        @{
            name = "lb-$($port.port)"
            port = $port.port
            targetPort = $address -eq "127.0.0.1" ? $port.nodePort : $port.port
            service = $srv.metadata.name
            address = $address
        }
    }

    # forward NodePort port
    if($ForwardNodePort -and $null -ne $port.nodePort -and ($srv.spec.type -eq "LoadBalancer" -or $srv.spec.type -eq "NodePort")) 
    {
        Write-Host ($port.nodePort.GetType())
        Write-Host "$($srv.metadata.name):$($port.port) registered port $($port.nodePort) forwarding to 127.0.0.1"
        
        @{
            name = "nodeport-$($port.nodePort)"
            port = $port.nodePort - 10000
            targetPort = $port.nodePort
            service = $srv.metadata.name
            address = "127.0.0.1"
        }
    }
}

function Get-ConfigContent($forwardings)
{
    foreach($forwading in $forwardings)
    {

@"
service srv-$($forwading.service)-$($forwading.name)
{
    disable = no
    type = UNLISTED
    socket_type = stream
    protocol = tcp
    wait = no
    redirect = $($forwading.address) $($forwading.targetPort)
    bind = 0.0.0.0
    port = $($forwading.port)
    user = nobody
}


"@
    }
}

function Start-Main() {
    Write-Host "Discovering services..."
    $services = Get-K8sServices
    Write-Verbose ($services | ConvertTo-Json -Depth 99)
    $forwardings = $services.items | % { Handle-Service -srv $_ }

    Write-Host "Generating configuration..."
    $configContent = Get-ConfigContent -forwardings $forwardings
    $configContent ??= "# $(Get-Date): No services to expose found, check configuration if this is unexpected"
    $configContent = $configContent -join ''

    Write-Host "Created following xinetd configuration..."
    Write-Host $configContent

    Write-Host "Saving changes to $ConfigFilePath..."
    $configContent -replace "`r","" | Set-Content $ConfigFilePath -NoNewLine

    if($RunCommandsOnHost)
    {
        Write-Host "Checking if xinetd is installed on host"
        nsenter --target 1 --mount --uts --ipc --net sh -c "! command -v xinetd && apt-get install xinetd --yes"

        Write-Host "Restarting xinetd on the host..."
        nsenter --target 1 --mount --uts --ipc --net sh -c "systemctl restart xinetd && systemctl status xinetd"
    }
}

Start-Main