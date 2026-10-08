# Pokimon compartido

La misma partida de **COBBLEVERSE en Modrinth** para Porotecnia y Lacuina. Cada uno puede alojarla en su PC cuando el otro termine. El acceso del escritorio descarga los últimos avances antes de abrir Minecraft y sube una copia verificada al terminar el servidor.

**[Descargar instalador para Windows](https://github.com/Mirkovic-beep/pokimon-server-sync/releases/download/instalador-v1.0.0/Pokimon-Instalador-Windows.zip)** · [Copias de la partida](https://github.com/Mirkovic-beep/pokimon-server-sync/releases) · [Guía breve](LEEME-PRIMERO.txt)

## Instalar en el segundo PC

1. Mantén tu instancia habitual de COBBLEVERSE en Modrinth, con la que ya entrabas al servidor. Cierra Minecraft.
2. Descarga el instalador, extrae **todo el ZIP** y abre **Instalar Pokimon.cmd**. Se instala en `Games\Pokimon-Compartido` de tu usuario.
3. Conecta **tu propia cuenta de GitHub**. Mirkovic-beep debe añadir esa cuenta como colaboradora y hay que aceptar la invitación. Un repositorio público permite descargar, pero solo sus colaboradores pueden guardar cambios.
4. Acepta la EULA de Minecraft y espera a que termine la primera descarga. Deja al menos **65 GB libres**. La partida inicial comprimida ocupa unos **11,4 GB**; el tiempo depende de la conexión.

El instalador detecta Java 21 de Modrinth, prepara Fabric 0.18.4 para Minecraft 1.21.1 y verifica los 103 mods por SHA-256. Reutiliza los archivos correctos de tu instancia y descarga los que falten desde Modrinth. Un mod incluido en el paquete, `cobblemon-battle-positions-1.1.3.jar`, debe estar en tu instancia con su versión original. La instancia del cliente no se modifica salvo añadir una entrada a Multijugador, conservando una copia previa de `servers.dat`.

No hacen falta Git, comandos `pull`/`push`, copiar mundos a mano ni instalar Java aparte. GitHub CLI se descarga de su distribución oficial y gestiona el inicio de sesión de cada PC.

## Jugar y ceder el turno

1. Abre **Iniciar servidor Pokimon** en el escritorio. Se comprueba la última versión y se reserva el turno. Espera a que Minecraft muestre `Done`.
2. Abre COBBLEVERSE desde Modrinth → **Multijugador → Pokimon - partida compartida**. En el primer PC la entrada local puede conservar su nombre anterior. También sirve Conexión directa con `localhost:25565`.
3. Al acabar, escribe **`stop` en la consola del servidor**. Espera a **LISTO: ya puede abrir el servidor el otro PC** antes de cerrar la ventana o apagar el equipo.

Cerrar solo el cliente Minecraft no detiene el servidor ni dispara la subida. Mientras haya una sesión o subida pendiente, el otro PC no puede abrir otra copia. Para jugar juntos, ambos entran en el mismo servidor anfitrión.

El primer PC conserva **12 GB** de memoria máxima para el servidor. En instalaciones nuevas se detecta la RAM: 12 GB para equipos de al menos 24 GB, 6 GB si tienen al menos 16 GB y 4 GB en equipos más pequeños. Con menos de 16 GB puede ir lento al alojar y jugar en el mismo PC.

## Si se interrumpe algo

- **Subida o Internet interrumpidos:** vuelve a abrir el mismo acceso, o usa **Reintentar subida Pokimon**. Se aprovechan los adjuntos completos y se conserva la reserva hasta terminar.
- **Servidor cerrado con la X o apagón:** el mismo PC recupera su mundo local al volver a abrirlo. No descarga encima de esos avances. Después hay que terminar con `stop`.
- **Restauración interrumpida:** el registro local permite recuperar la partida anterior antes de continuar. La sustitución conserva una copia completa anterior.
- **Otro PC ocupado:** espera a que termine allí. Las reservas **no caducan automáticamente**; hacerlo permitiría abrir dos mundos distintos durante un corte de red. Si se pierde el PC que tenía la reserva, hace falta revisar y recuperar la última copia publicada antes de liberar su turno.
- **Cambios hechos fuera del lanzador:** se detiene la sincronización y se conservan. No uses el antiguo mundo de un jugador ni arranques Java directamente para continuar esta partida compartida.

No borres `sync-state` ni `server` para resolver un error: contienen el estado y los avances pendientes. Una ventana indica claramente si falta terminar la subida.

## Qué se conserva

La copia incluye el mundo entero: jugadores e inventarios, Pokémon del equipo y del PC, monedas, mochilas, cofres, construcciones, dimensiones y progreso de mods. También incluye datos persistentes de mods fuera del mundo, configuraciones, datapacks, operadores y lista de acceso. Porotecnia y Lacuina conservan sus UUID y OP.

Los **mapas explorados y puntos personales de Xaero** pertenecen a cada cliente y permanecen en su instancia de Modrinth. No se mezclan ni se distribuyen como parte del mundo del servidor. Al cambiar de dirección, Xaero puede mostrar otro mapa; el anterior sigue guardado y requiere asociarlo a la nueva dirección.

Cada archivo tiene SHA-256 en el manifiesto. Las copias se comprimen en ZIP64 y se suben en partes de hasta 1 GiB. La Release sigue en borrador hasta verificar en GitHub el tamaño y hash de todos los adjuntos. Después se actualiza el estado compartido mediante una escritura condicionada al SHA anterior; si otro arranque ganó la reserva, no se fuerza la escritura.

El mundo va en **Releases**, sin Git LFS ni binarios grandes en el historial de Git. La rama `pokimon-state` contiene la reserva y la referencia exacta de la última partida completa; las instalaciones no se fían simplemente de la Release marcada como «Latest».

## Espacio, red y acceso

Se conservan las dos últimas copias locales completas generadas por el lanzador, una partida anterior a la última restauración y la copia inicial del primer PC. Antes de limpiar copias locales más antiguas se comprueba que sus adjuntos siguen completos en GitHub. Las descargas temporales se eliminan después de aplicarlas y verificarlas. Las copias publicadas en GitHub no se borran automáticamente. Los respaldos originales de Modrinth del primer PC quedan fuera de esta limpieza.

**GitHub almacena la partida; el PC elegido ejecuta el servidor y debe permanecer encendido mientras se juega.** Para conectarse desde otro domicilio hacen falta la IP y el puerto accesible del PC anfitrión. El puerto configurado en el router del primer PC no se traslada al router del segundo. Este instalador permite jugar localmente al anfitrión; no configura un router remoto.

**Este repositorio y sus copias son públicos:** cualquiera puede descargar el mundo. Las credenciales se quedan en cada PC mediante GitHub CLI. No se suben registros de conexiones, archivos del router, contraseñas ni las credenciales locales.

## Comprobaciones técnicas

`Test-Sync.ps1` comprueba los archivos multipartes, restauración, datos de mods, hashes, rutas de extracción, interrupciones y publicación solo al terminar. `Test-Shared.ps1` simula dos PCs, protege avances locales, comprueba reintentos y cierres anómalos, recuperación tras una sustitución interrumpida y limpieza de copias. `Test-LiveCoordination.ps1` comprueba reservas y conflictos contra la API real en un archivo temporal separado del estado de producción.

El instalador y los accesos usan `Install-Pokimon.ps1` y `Start-SharedServer.ps1`. Los antiguos `Enable-AutoBackup.ps1`, `After-ServerStop.ps1` y `Retry-Upload.ps1` solo corresponden al modo de copias de un único anfitrión; no se usan en esta instalación compartida.

Referencias: [almacenamiento de Releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases#storage-and-bandwidth-quotas), [actualización condicionada de archivos](https://docs.github.com/en/rest/repos/contents#create-or-update-file-contents), [hashes de versiones de Modrinth](https://docs.modrinth.com/api/operations/versionsfromhashes/). GitHub no proporciona un servidor de juego ni una garantía de alojamiento ilimitado de copias.
