######################################################################################################################################
## Asegúrese de que los módulos Az están instalados en su sistema ejecutando 'Install-Module Az'
######################################################################################################################################

$tenantId = "tenantId"
$subscriptionId = "subscriptionId"
$capacityId = ""
$projectName = "projectName"
$layers = @("01_Bronze","02_Silver","03_Gold") # Cambiar nombre de las capas y añadir o quitar según necesidad
$medallionInOneWorkspace = $false
$azureKeyVault = $false
$azureKeyVaultName = "azureKeyVaultName"

if (-not $tenantId) {
    Write-Error "El parámetro 'tenantId' es obligatorio. Por favor, configúralo en el script antes de ejecutarlo."
    exit 1 
}
elseif (-not $subscriptionId){
    Write-Error "El parámetro 'subscriptionId' es obligatorio. Por favor, configúralo en el script antes de ejecutarlo."
    exit 1 
}
elseif (-not $projectName){
    Write-Error "El parámetro 'projectName' es obligatorio. Por favor, configúralo en el script antes de ejecutarlo."
    exit 1 
}
elseif (-not $layers -or $layers.Count -eq 0){
    Write-Error "El parámetro 'layers' es obligatorio y debe contener al menos un elemento."
    exit 1 
}

if($azureKeyVault -and -not $azureKeyVaultName)
{
    Write-Error "Error: Se requiere el parámetro 'azureKeyVaultName' cuando 'azureKeyVault' está habilitado (true). Configure 'azureKeyVaultName' y vuelva a ejecutar el script."
    exit 1
}


# URL base de la api de Microsoft Fabric
$baseFabricUrl = "https://api.fabric.microsoft.com"

# Inicio de sesión en Fabric
Connect-AzAccount -TenantId $tenantId -Subscription $subscriptionId | Out-Null

# Obtenemos el token
$fabricToken = (Get-AzAccessToken -ResourceUrl $baseFabricUrl).Token

# Crear cabeceras para las llamadas a la API
$headerParams = @{'Authorization'="Bearer {0}" -f $fabricToken}
$contentType = @{'Content-Type' = "application/json"}


$seleccionCapacidad = $false
$opcionesCapacidades = @()

if (-not $capacityId) {
    Write-Host "Es necesario especificar el id de la capacidad que se va a utilizar. A continuación se muestran las capacidades disponibles, selecciona cual quieres utilizar:"
    Write-Host ""
    $capacitiesUri = "{0}/v1/capacities" -f $baseFabricUrl
    $capacitiesList = Invoke-RestMethod -Headers $headerParams -ContentType $contentType -Method GET -Uri $capacitiesUri

    foreach ($capacity in $capacitiesList.value) {
        Write-Host "ID de la capacidad: $($capacity.id)"
        Write-Host "Nombre de la capacidad: $($capacity.displayName)"
        Write-Host "SKU: $($capacity.sku)"
        Write-Host "Region: $($capacity.region)"
        Write-Host "Estado: $($capacity.state)"
        Write-Host ""
        $opcionesCapacidades += $capacity.displayName
    }

    $opcionesCapacidades += "Salir"
    $valorSeleccionado = $null

    while (-not $seleccionCapacidad) {
        # Mostramos las opciones
        Write-Host "Por favor, escribe el nombre de la capacidad que quieres utilizar:"
        $opcionesCapacidades | ForEach-Object { Write-Host "- $_" }

        # Pedimos seleccionar la capacidad
        $valorSeleccionado = Read-Host "Ingrese su elección"

        # Validar la selección
        if ($opcionesCapacidades -contains $valorSeleccionado) {
            if ($valorSeleccionado -eq "Salir") {
                Write-Host "Has decidido finalizar la ejecución. Saliendo..." -ForegroundColor Red
                Exit
            } else {
                Write-Host "Has seleccionado: $valorSeleccionado" -ForegroundColor Green
                foreach ($capacity in $capacitiesList.value){
                    if($capacity.displayName -eq $valorSeleccionado){
                        $capacityId = $capacity.id
                        Write-Host "El ID de la capacidad seleccionada es: $($capacity.id)" -ForegroundColor Green
                    }
                }
                $seleccionCapacidad = $true

            }
        } else {
            Write-Host "Selección no válida. Inténtalo de nuevo." -ForegroundColor Yellow
        }
    }

}

Write-Host ""

$workspacesDisponibles = @()
$workspaceId = ""


# Si la variable es true, generamos todo en un área de trabajo
if ($medallionInOneWorkspace)
{
    ######################################################################################################################################
    ## ÁREA DE TRABAJO
    ##
    ## Se comprueba si existe el área de trabajo. Si existe, obtenemos el workspaceId, sino, creamos el área de trabajo
    ## y obtenemos el workspaceId.
    ##
    ######################################################################################################################################

    Write-Host "El script está configurado para crear todo en una área de trabajo"
    Write-Host "Inicializando la creación del área de trabajo..."
    Write-Host ""

    # Listamos las áreas de trabajo
    $workspacesUri = "{0}/v1/workspaces" -f $baseFabricUrl
    $workspacesList = Invoke-RestMethod -Headers $headerParams -ContentType $contentType -Method GET -Uri $workspacesUri
    foreach ($workspace in $workspacesList.value) 
    {
        $workspacesDisponibles += $workspace.displayName
    }

    if ($workspacesDisponibles -contains $projectName)
    {
        Write-Host "El workspace $($projectName) ya existe. Se crearán los objetos sobre esta área de trabajo."
        foreach ($workspace in $workspacesList.value) 
        {
            if($workspace.displayName -eq $projectName)
            {
                $workspaceId = $workspace.id
                Write-Host "Workspace Name: $($workspace.displayName)" -ForegroundColor Cyan
                Write-Host "Workspace ID: $($workspace.id)" -ForegroundColor Cyan
                Write-Host "Capacity ID: $($workspace.capacityId)" -ForegroundColor Cyan
                Write-Host ""
            }
        }

        if($azureKeyVault)
        {
            # Establecer los valores de los secretos del Workspace al KeyVault
            $body = @{
                "value" = $workspace.id
            } | ConvertTo-Json -Depth 1

            try{
                $secureStringValue = ConvertTo-SecureString -String $workspaceId -AsPlainText -Force
                Set-AzKeyVaultSecret -VaultName $azureKeyVaultName -Name "$($projectName)-workspace-id".ToLower().Replace("_", "-") -SecretValue $secureStringValue
            }
            catch {
                Write-Host "Error al establecer el valor del secreto: $($_.Exception.Message)" -ForegroundColor Red
                exit 1 
            }
        }        
    }
    else
    {
        Write-Host "Creando área de trabajo $($projectName)..."
        $body = @{
            "displayName" = $projectName;
            "capacityId" = $capacityId
        } | ConvertTo-Json -Depth 10

        try {
            $response = Invoke-RestMethod -Headers $headerParams -Method POST -Uri $workspacesUri -Body $body -ContentType "application/json"
            Write-Host "Área de trabajo creada con éxito:" -ForegroundColor Green
            Write-Host "ID del área de trabajo: $($response.id)" -ForegroundColor Green
            Write-Host ""
            $workspaceId = $response.id

            if($azureKeyVault)
            {
                # Establecer los valores de los secretos del Workspace al KeyVault
                $body = @{
                    "value" = $response.id
                } | ConvertTo-Json -Depth 1

                try{
                    $secureStringValue = ConvertTo-SecureString -String $response.id -AsPlainText -Force
                    Set-AzKeyVaultSecret -VaultName $azureKeyVaultName -Name "$($projectName)-workspace-id".ToLower().Replace("_", "-") -SecretValue $secureStringValue
                }
                catch {
                    Write-Host "Error al establecer el valor del secreto: $($_.Exception.Message)" -ForegroundColor Red
                    exit 1 
                }
            }
        } 
        catch {
            Write-Host "Error al crear el área de trabajo: $($_.Exception.Message)" -ForegroundColor Red
            exit 1 
        }

    }

    ######################################################################################################################################
    ## LAKEHOUSE
    ##
    ## Se crean tantos lakehouse como capas se hayan definido con la nomenclatura (projectName)_(layer)
    ##
    ######################################################################################################################################

    Write-Host "Inicializando la creación de los lakehouses..."
    Write-Host ""

    $lakehousesUri = "{0}/v1/workspaces/{1}/lakehouses" -f $baseFabricUrl, $workspaceId
    $lakehousesList = Invoke-RestMethod -Headers $headerParams -ContentType $contentType -Method GET -Uri $lakehousesUri
    $lakehousesExistentes = @()

    try {
        $lakehousesList = Invoke-RestMethod -Headers $headerParams -ContentType $contentType -Method GET -Uri $lakehousesUri
        if (-not $lakehousesList) 
        {
            Write-Host "La API no devolvió ningún lakehouse." -ForegroundColor Yellow
        } 
        else 
        {
            foreach ($lakehouse in $lakehousesList.value) {
                $lakehousesExistentes += $lakehouse.displayName
            }
        }
    } 
    catch {
        Write-Host "Error al obtener los lakehouses: $($_.Exception.Message)" -ForegroundColor Red
    }

    foreach ($layer in $layers) 
    {
        $lakehouseName = "$projectName`_$layer`_lh"

        if($lakehousesExistentes -notcontains $lakehouseName)
        {
            Write-Host "Creando lakehouse $($lakehouseName)..."
            $body = @{
                "displayName" = $lakehouseName
            } | ConvertTo-Json -Depth 10

            try {
                $response = Invoke-RestMethod -Headers $headerParams -Method POST -Uri $lakehousesUri -Body $body -ContentType "application/json"
                Write-Host "Lakehouse $($lakehouseName) creado con éxito:" -ForegroundColor Green
                Write-Host "ID del lakehouse: $($response.id)" -ForegroundColor Green

                if($azureKeyVault)
                {
                    $body = @{
                        "value" = $response.id
                    } | ConvertTo-Json -Depth 1

                    try{
                        $secureStringValue = ConvertTo-SecureString -String $response.id -AsPlainText -Force
                        Set-AzKeyVaultSecret -VaultName $azureKeyVaultName -Name "$projectName-$layer-lh-id".ToLower().Replace("_", "-") -SecretValue $secureStringValue
                    }
                    catch {
                        Write-Host "Error al establecer el valor del secreto: $($_.Exception.Message)" -ForegroundColor Red
                        exit 1 
                    }
                }
            } 
            catch {
                Write-Host "Error al crear el lakehouse: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        else{
            Write-Host "El lakehouse $($lakehouseName) ya existe." -ForegroundColor Yellow
        }
        Write-Host ""
    }

}
# Si la variable es false, generamos cada capa en un área de trabajo distinta
else
{
    ######################################################################################################################################
    ## ÁREA DE TRABAJO
    ##
    ## Se comprueba si existe el área de trabajo. Si existe, obtenemos el workspaceId, sino, creamos el área de trabajo
    ## y obtenemos el workspaceId.
    ##
    ######################################################################################################################################

    Write-Host "El script está configurado para crear un área de trabajo para cada capa"
    Write-Host "Inicializando la creación del área de trabajo..."
    Write-Host ""

    # Listamos las áreas de trabajo
    $workspacesUri = "{0}/v1/workspaces" -f $baseFabricUrl
    $workspacesList = Invoke-RestMethod -Headers $headerParams -ContentType $contentType -Method GET -Uri $workspacesUri
    foreach ($workspace in $workspacesList.value) 
    {
        $workspacesDisponibles += $workspace.displayName
    }

    foreach ($layer in $layers) {
        $WorkspaceName = "$projectName`_$layer"

        if ($workspacesDisponibles -contains $WorkspaceName) {
            Write-Host "El workspace $($WorkspaceName) ya existe. Se crearán los objetos sobre esta área de trabajo."
            foreach ($workspace in $workspacesList.value) 
            {
                if($workspace.displayName -eq $WorkspaceName)
                {
                    $workspaceId = $workspace.id
                    Write-Host "Workspace Name: $($workspace.displayName)" -ForegroundColor Cyan
                    Write-Host "Workspace ID: $($workspace.id)" -ForegroundColor Cyan
                    Write-Host "Capacity ID: $($workspace.capacityId)" -ForegroundColor Cyan
                    Write-Host ""
                }
            }

            if($azureKeyVault)
            {
                # Establecer los valores de los secretos del Workspace al KeyVault
                $body = @{
                    "value" = $workspace.id
                } | ConvertTo-Json -Depth 1

                try{
                    $secureStringValue = ConvertTo-SecureString -String $workspaceId -AsPlainText -Force
                    Set-AzKeyVaultSecret -VaultName $azureKeyVaultName -Name "$($projectName)-$($layer)-workspace-id".ToLower().Replace("_", "-") -SecretValue $secureStringValue
                }
                catch {
                    Write-Host "Error al establecer el valor del secreto: $($_.Exception.Message)" -ForegroundColor Red
                    exit 1 
                }
            }
        } else {
            Write-Host "Creando área de trabajo $($WorkspaceName)..."
            $body = @{
                "displayName" = $WorkspaceName;
                "capacityId" = $capacityId
            } | ConvertTo-Json -Depth 10

            try {
                $response = Invoke-RestMethod -Headers $headerParams -Method POST -Uri $workspacesUri -Body $body -ContentType "application/json"
                Write-Host "Área de trabajo creada con éxito:" -ForegroundColor Green
                Write-Host "ID del área de trabajo: $($response.id)" -ForegroundColor Green
                Write-Host ""
                $workspaceId = $response.id

                if($azureKeyVault)
                {
                    # Establecer los valores de los secretos del Workspace al KeyVault
                    $body = @{
                        "value" = $response.id
                    } | ConvertTo-Json -Depth 1

                    try{
                        $secureStringValue = ConvertTo-SecureString -String $response.id -AsPlainText -Force
                        Set-AzKeyVaultSecret -VaultName $azureKeyVaultName -Name "$($projectName)-$($layer)-workspace-id".ToLower().Replace("_", "-") -SecretValue $secureStringValue
                    }
                    catch {
                        Write-Host "Error al establecer el valor del secreto: $($_.Exception.Message)" -ForegroundColor Red
                        exit 1 
                    }
                }
            } 
            catch {
                Write-Host "Error al crear el área de trabajo: $($_.Exception.Message)" -ForegroundColor Red
                exit 1 
            }
        }


        ######################################################################################################################################
        ## LAKEHOUSE
        ##
        ## Se crea el lakehouse correspondiente de la capa
        ##
        ######################################################################################################################################

        Write-Host "Inicializando la creación del lakehouse..."
        Write-Host ""

        $lakehousesUri = "{0}/v1/workspaces/{1}/lakehouses" -f $baseFabricUrl, $workspaceId
        $lakehousesList = Invoke-RestMethod -Headers $headerParams -ContentType $contentType -Method GET -Uri $lakehousesUri
        $lakehousesExistentes = @()

        try {
            $lakehousesList = Invoke-RestMethod -Headers $headerParams -ContentType $contentType -Method GET -Uri $lakehousesUri
            if (-not $lakehousesList) 
            {
                Write-Host "La API no devolvió ningún lakehouse." -ForegroundColor Yellow
            } 
            else 
            {
                foreach ($lakehouse in $lakehousesList.value) {
                    $lakehousesExistentes += $lakehouse.displayName
                }
            }
        } 
        catch {
            Write-Host "Error al obtener los lakehouses: $($_.Exception.Message)" -ForegroundColor Red
        }


        $lakehouseName = "$projectName`_$layer`_lh"
        if($lakehousesExistentes -notcontains $lakehouseName)
        {
            Write-Host "Creando lakehouse $($lakehouseName)..."
            $body = @{
                "displayName" = $lakehouseName
            } | ConvertTo-Json -Depth 10

            try {
                $response = Invoke-RestMethod -Headers $headerParams -Method POST -Uri $lakehousesUri -Body $body -ContentType "application/json"
                Write-Host "Lakehouse $($lakehouseName) creado con éxito:" -ForegroundColor Green
                Write-Host "ID del lakehouse: $($response.id)" -ForegroundColor Green

                if($azureKeyVault)
                {
                    $body = @{
                        "value" = $response.id
                    } | ConvertTo-Json -Depth 1

                    try{
                        $secureStringValue = ConvertTo-SecureString -String $response.id -AsPlainText -Force
                        Set-AzKeyVaultSecret -VaultName $azureKeyVaultName -Name "$($projectName)-$($layer)-lh-id".ToLower().Replace("_", "-") -SecretValue $secureStringValue
                    }
                    catch {
                        Write-Host "Error al establecer el valor del secreto: $($_.Exception.Message)" -ForegroundColor Red
                        exit 1 
                    }
                }
            } 
            catch {
                Write-Host "Error al crear el lakehouse: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        else{
            Write-Host "El lakehouse $($lakehouseName) ya existe." -ForegroundColor Yellow
        }
        Write-Host ""


    }
}
