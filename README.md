# Mis trabajos — Gestor académico

Versión web adaptada para cuentas personales, sincronización en la nube, PDF privados y espacios compartidos mediante código.

## Archivos

- `index.html`: aplicación web.
- `supabase.sql`: tablas, permisos RLS, función segura para compartir y bucket privado de PDF.
- `original-referencia.txt`: copia del código que se usó como referencia (no es necesario publicarlo).

## 1. Crear el proyecto Supabase

1. Entra en https://supabase.com/ y crea un proyecto.
2. Abre **SQL Editor** → **New query**.
3. Copia el contenido completo de `supabase.sql`, pégalo y ejecuta la consulta.
4. En **Project Settings / API** o **Connect**, copia el Project URL y la **Publishable key** (o la `anon` key heredada si tu proyecto todavía la muestra).
5. Nunca copies una `service_role` o `secret key` al navegador.

## 2. Configurar el HTML

Abre `index.html` con un editor de texto y busca estas dos líneas al principio del script:

```js
const SUPABASE_URL='PEGA_AQUI_TU_PROJECT_URL';
const SUPABASE_PUBLISHABLE_KEY='PEGA_AQUI_TU_PUBLISHABLE_KEY';
```

Sustituye los textos de ejemplo por los valores de tu proyecto Supabase. Conserva las comillas. La publishable key está diseñada para usarse en el cliente, pero la seguridad real depende de las políticas RLS incluidas en el SQL.

## 3. Ajustar autenticación

En Supabase abre **Authentication → URL Configuration**:

- Configura **Site URL** con la URL que Vercel te asigne, por ejemplo `https://tu-proyecto.vercel.app`.
- Añade esa URL en **Redirect URLs**.
- Para probar en local, añade también `http://localhost:8000/**`.
- Decide en **Authentication → Providers → Email** si exigirás confirmación por correo. Si la confirmación está activa, la persona debe confirmar su dirección antes de entrar.

## 4. Probar en tu computadora

No es recomendable abrir el archivo mediante `file://` si vas a probar enlaces de autenticación. Dentro de la carpeta del proyecto, inicia un servidor local:

```bash
python -m http.server 8000
```

Después abre `http://localhost:8000`. Registra una cuenta de prueba, crea un curso, añade un trabajo y sube un PDF. Comprueba también la opción de compartir con un segundo usuario.

## 5. Publicar con GitHub y Vercel

1. Crea una cuenta en https://github.com/ y un repositorio nuevo.
2. Sube `index.html` y los archivos del proyecto. No publiques claves secretas ni archivos con contraseñas. El archivo `original-referencia.txt` no es necesario para la aplicación publicada.
3. Entra en https://vercel.com/, selecciona **Add New → Project** y conecta el repositorio de GitHub.
4. Para este HTML estático, deja el framework como **Other** y la raíz del proyecto como la carpeta que contiene `index.html`; no hace falta comando de build ni directorio de salida especial.
5. Pulsa **Deploy** y espera a que Vercel genere la URL pública.
6. Copia esa URL a Supabase **Authentication → URL Configuration** como Site URL y Redirect URL.
7. Abre el enlace desde otro dispositivo y prueba registro, inicio de sesión, PDF y códigos de compartir.

## 6. Qué protege esta versión

- RLS restringe las tablas de cursos y trabajos al usuario autenticado propietario.
- Los PDF se guardan en un bucket privado, dentro de una carpeta con el ID del usuario. La vista previa usa enlaces firmados temporales.
- La función `get_shared_workspace` devuelve únicamente nombre, cursos y tareas; no devuelve rutas de PDF ni permite modificar datos.
- Desactivar el espacio compartido invalida el código.

## Limitaciones que debes conocer antes de usarla en producción

- Esta es una base funcional para desplegar y probar, no una auditoría de seguridad independiente. Prueba siempre con dos cuentas diferentes.
- Los espacios compartidos muestran todos los cursos y trabajos del propietario; el código actual no tiene selección por curso.
- Los PDF no se comparten con las personas que tienen el código.
- La interfaz conserva las funciones principales, pero todavía no incluye una pantalla para eliminar cursos ni una función de exportación.
- La contraseña mínima de la interfaz es de 8 caracteres; revisa también los ajustes de seguridad y límites de autenticación del proyecto Supabase.
- Para una aplicación con muchos usuarios, conviene añadir límites de tamaño/tipo, tratamiento de errores más exhaustivo, limpieza de archivos huérfanos, pruebas RLS automatizadas y una revisión de accesibilidad.


## Compartir trabajos y permitir descargar los PDF

La versión actualizada permite que quien introduzca un código de espacio compartido pueda ver los trabajos, abrir las guías PDF y descargar los archivos adjuntos. Los archivos permanecen en el bucket privado; una política de Storage solo permite leer una ruta si está asociada a un trabajo de un propietario que mantiene activado el espacio compartido. Al desactivar el espacio, deja de autorizar nuevas descargas/enlaces firmados. Los enlaces firmados ya emitidos pueden funcionar hasta que expiren (120 segundos).

Si ya ejecutaste una versión anterior de `supabase.sql`, vuelve a ejecutar el archivo completo actualizado desde Supabase > SQL Editor. El script actualiza la función RPC y añade la función/política para acceso de lectura compartida a PDF. No elimines tablas ni datos.
