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
3. **SQL Editor**: pega el archivo `roles_admin.sql` y dale **Run**. Así se activan los roles de administrador y comunidad y el panel **Admin**.

4. **SQL Editor**: pega `via_libre.sql` y luego `planes.sql`, y dale **Run** a cada uno. Así se activan el tipo "Libre de agentes" y los planes Plus y Empresa.

## Planes

- **Gratis**: mapa en vivo, reportes, alertas a 5 km, insignia de zona y vista de calle.
- **Plus** ($6.900/mes): modo conducción con avisos por voz a 500 m, alertas a 20 km e insignia Plus.
- **Empresa** ($89.900/mes): Plus para hasta 10 conductores y panel "Mi empresa".
- El cobro es manual: el usuario paga, envía la referencia y el admin aprueba en **Admin → Planes**, donde también se editan precios y datos de pago.

5. **SQL Editor**: pega `finanzas.sql` y dale **Run**. Así se activan los meses con descuento y el registro financiero.

## Finanzas (Admin → Finanzas)

- Cada plan aprobado queda registrado en un libro de pagos con número consecutivo (desde el 1001).
- Muestra los ingresos del mes o del año, una gráfica por mes, los ingresos por tipo y el ingreso mensual recurrente.
- Tiene recibo imprimible o en PDF, exportación a Excel (CSV), registro de pagos manuales y anulaciones con motivo. Los pagos nunca se borran.
- Es un soporte interno: no reemplaza la factura electrónica de la DIAN.

## Roles

- **Comunidad**: publica reportes, confirma alertas ("Sigue ahí") y comenta. Su celular solo lo ve el administrador.
- **Administrador**: tiene la pestaña **Admin**, con resumen, todos los reportes de 7 días, usuarios y comentarios. Puede borrar reportes y comentarios, bloquear o desbloquear usuarios y nombrar a otros administradores.

## Archivos

- `index.html`: toda la aplicación.
- `privacidad.html`: política de privacidad (Ley 1581 de 2012).
- `img/`: logo e íconos de Orion Nova.
