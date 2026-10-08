# Copias del servidor Pokimon

Herramientas para publicar copias completas de un servidor de Minecraft Java en GitHub Releases. Los scripts se guardan en Git; el mundo comprimido se adjunta a cada Release en partes de hasta 1 GiB. No se utiliza Git LFS.

## Funcionamiento

El modo preparado es **un solo PC anfitrión**. Al escribir `stop`, Minecraft guarda y se apaga. El lanzador prepara la copia, comprueba sus archivos y la publica. Hay que dejar la consola abierta hasta que indique **Copia completa y verificada**. Cerrar solo el cliente Minecraft no apaga el servidor.

La publicación permanece como borrador mientras faltan adjuntos. Solo se publica cuando GitHub confirma el tamaño y SHA-256 de todas las partes y del manifiesto. Una interrupción conserva la copia local y permite reintentar los adjuntos que faltan. Si Minecraft termina con error, el guardado no se anuncia automáticamente como completo.

La copia incluye el mundo completo —jugadores, inventarios, Pokémon, cofres, dimensiones y datos de mods—, las carpetas de datos externos de los mods, configuraciones, datapacks, operadores y lista de acceso. La operación obtiene un bloqueo exclusivo del mundo durante la compresión para impedir una copia mientras Minecraft lo usa.

El manifiesto identifica por SHA-256 los mods necesarios, que deben estar instalados en el equipo que restaure la partida. Los ejecutables y JAR de mods, bibliotecas descargables, registros, archivos del router y credenciales quedan fuera de los archivos seleccionados. Los mapas y puntos personales de Xaero pertenecen a cada cliente y se conservan por separado. Una comprobación de posibles credenciales bloquea la publicación si detecta una clave en los archivos seleccionados; no sustituye una revisión de lo que se decide publicar.

**El repositorio y sus copias son públicos:** otras personas podrán descargar la partida. El servidor de juego continúa alojado en el PC anfitrión; GitHub almacena las copias.

## Preparación

Requisitos: Windows PowerShell 5.1, Git, GitHub CLI conectado a la cuenta del propietario, el servidor preparado y espacio libre para el ZIP y sus partes. Para conectar GitHub CLI se usa su inicio de sesión oficial: `gh auth login --hostname github.com --git-protocol https --web`.

1. Guardar una copia de `settings.example.json` **fuera del repositorio**, ajustando las rutas y `repository`. Dejar `enabled` en `false` hasta activar el lanzador.
2. Ejecutar `Initialize-GitHub.ps1 -SettingsPath RUTA` para crear el repositorio público y subir estos scripts.
3. Ejecutar `Test-Sync.ps1 -TestDirectory RUTA_NUEVA` para comprobar compresión, recuperación, corrupción, interrupción de subida y publicación. El transporte de red de estas pruebas es simulado.
4. Tras comprobar el acceso real a GitHub, ejecutar `Enable-AutoBackup.ps1 -SettingsPath RUTA`. Conserva el lanzador anterior como `Start-Server-without-backup.ps1`; el acceso habitual del escritorio sigue usando `Start-Server.ps1`.
5. Iniciar el servidor con ese acceso y terminar con `stop`. Esperar la confirmación de publicación. La activación modifica los siguientes arranques; una consola que ya estaba abierta mantiene el código anterior.

No se extraen cookies del navegador ni tokens de otros programas. GitHub CLI administra su propia autenticación. La configuración local y los archivos de trabajo no se añaden a Git.

## Reintentar o recuperar una copia

`Retry-Upload.ps1 -SettingsPath RUTA` vuelve a intentar, por orden, las copias completas pendientes de subir. No sustituye una copia local corrupta por otra ni reemplaza adjuntos remotos que tengan un hash distinto: esos casos requieren revisar el error.

`Download-Latest.ps1 -SettingsPath RUTA -Destination CARPETA_NUEVA` descarga la última copia publicada, valida todas sus partes y comprueba el SHA-256 de cada archivo al extraerlo. Prepara una carpeta nueva para revisar y recuperar; no modifica el mundo que se está jugando. La lista de mods del manifiesto permite comprobar que el servidor de destino tiene las mismas versiones.

Este modo no realiza un `pull` del mundo al iniciar ni coordina dos anfitriones. Para alternar servidores hacen falta un bloqueo de sesión compartido, detección de cambios locales y una restauración automática que evite sobrescribir avances. No se debe usar esta modalidad como si ya ofreciera esas garantías.

Las copias locales y las Releases antiguas se conservan. La herramienta comprueba el espacio libre antes de empezar y no elimina automáticamente respaldos. Una copia completa de un mundo grande puede tardar varios minutos en comprimirse y subirse; el tiempo depende del disco y de la conexión.

## Verificación

Las pruebas usan un mundo artificial y una simulación de GitHub. Incluyen recuperación íntegra, rechazo de mundos bloqueados, partes corruptas, rutas que salen del destino, credenciales, adjuntos con hashes distintos, reintento de una subida interrumpida y publicación solo tras completar la verificación. Una prueba local no acredita por sí sola una subida real a GitHub.

Los [límites de Releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases#storage-and-bandwidth-quotas) permiten hasta 1000 adjuntos por Release, cada uno menor de 2 GiB. El historial de binarios se mantiene en Releases, como contempla la [documentación de archivos grandes](https://docs.github.com/en/repositories/working-with-files/managing-large-files/about-large-files-on-github#distributing-large-binaries).
