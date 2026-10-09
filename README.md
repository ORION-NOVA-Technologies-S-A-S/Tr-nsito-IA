# Alerta Tránsito · Orion Nova Technologies

Versión web de Alerta Tránsito. Es una comunidad que reporta fotomultas, retenes, controles, agentes y accidentes en tiempo real.

- Funciona en celular y computador. En el celular se puede instalar como app con "Agregar a pantalla de inicio".
- Base de datos: Supabase, proyecto **Alerta Transito**, separado de Nova.
- Mapa: OpenStreetMap con Leaflet. No requiere API key.

## Configuración en Supabase (una sola vez)

1. **Authentication → URL Configuration**
   - En **Site URL** pon la dirección de esta página, por ejemplo `https://carlos060801.github.io/alerta-transito/`.
   - Agrega esa misma dirección en **Redirect URLs**.
   - Esto hace que los enlaces de confirmación de cuenta y de recuperación de contraseña abran la app.
2. **SQL Editor**: pega el archivo `eliminar_cuenta.sql` y dale **Run**. Así se activa el botón "Eliminar mi cuenta".

## Archivos

- `index.html`: toda la aplicación.
- `privacidad.html`: política de privacidad (Ley 1581 de 2012).
- `img/`: logo e íconos de Orion Nova.
