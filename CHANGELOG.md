# Historial de cambios

## 1.0.1 - 2026-09-15

- Las carpetas nuevas de datos de RTFM se preparan para su usuario `10001:10001`, tanto en Unraid como en Linux.
- Las rutas existentes conservan su propietario y permisos; no se modifican sus contenidos.
- La simulación explica la preparación de permisos sin crear ni modificar carpetas.

## 1.0.0 - 2026-09-15

- Detección automática de Unraid y Linux sin una pregunta adicional antes del menú principal.
- Instalación con las plantillas de DockerMan en Unraid y con un archivo Compose por aplicación en Linux.
- Compatibilidad con servidores Intel/AMD de 64 bits y ARM de 64 bits, incluida Raspberry Pi 3 y posteriores con sistema operativo de 64 bits.
- Preparación de Docker y Compose desde el repositorio oficial, previa autorización, en Debian 12/13, Ubuntu 22.04/24.04/26.04 y Raspberry Pi OS de 64 bits basado en Debian 12/13.
- Reutilización de Docker existente; no se sustituyen paquetes incompatibles ni se reinicia un servicio en funcionamiento.
- Directorios propuestos propios de Linux: datos en `/srv/appdata`, archivos Compose en `/opt/zero-launcher` y registros en `/var/log/zero-launcher`.
- Simulación seleccionable de Unraid, Debian, Ubuntu y Raspberry Pi desde el mismo menú.
- Conservación de puertos, capacidades, usuario, restricciones y montajes al trasladar las plantillas a Compose.
- Comprobación de arquitectura en las imágenes que publican un índice de plataformas.
- Detención del proceso si falla una descarga, la preparación de Local Registry o la creación de un contenedor.
- Corrección de la documentación del simulador y comprobaciones limitadas a 20 casos.

## 0.2.0 - 2026-09-14

- Instalación asistida de los contenedores directamente desde la terminal de Unraid.
- Modo simulador para recorrer una instalación nueva sin tocar el equipo ni Docker.
- Alineación visual del texto y la atribución del recuadro principal.
- Selector múltiple tipo instalador de Linux con flechas, barra espaciadora y confirmación mediante Enter.
- Elección de imágenes públicas desde GHCR o copias privadas en Local Registry.
- Origen común al instalar toda la suite y selección independiente al elegir aplicaciones concretas.
- Detección de instalaciones existentes, incluidas las que están detenidas.
- Instalación inicial de Local Registry cuando una aplicación necesita imágenes locales.
- Local Registry continúa dependiendo de GHCR para poder arrancar y recuperarse.
- Personalización guiada de puertos y rutas persistentes con creación de carpetas inexistentes.
- Indicación clara de campos obligatorios sin valor previo y ejemplos seguros para recorrerlos en el simulador.
- Menú principal único antes y después de una instalación o simulación.
- Registro completo de la sesión con destino configurable y ruta predeterminada en el `appdata` de Zero Launcher.
- Conservación de icono, interfaz web, edición y administración desde DockerMan.
- Selección automática de `stable` o `dev` según las imágenes publicadas.
- Retirada completa de las tareas automáticas de GitHub.
- Soporte centralizado en la comunidad de Discord de Unraides.

## 0.1.0 - En desarrollo

- Primera interfaz interactiva para terminales Unraid.
- Selección de los canales `stable` y `dev`.
- Selección conjunta o individual de las cinco aplicaciones.
- Importación atómica de plantillas en DockerMan con copia de seguridad.
- Generación de plantillas para GHCR o para un registro Docker local.
- Descarga previa opcional de imágenes y sincronización con un registro local.
- Comprobación no destructiva de los contenedores de la suite.
- Identidad visual, documentación pública y empaquetado reproducible del script.
