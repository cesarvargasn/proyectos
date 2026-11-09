# Gastos y Transacciones

Registro automático de gastos a partir de los SMS y las notificaciones del banco.

- `Capturador/`: app Android (Kotlin, SQLite). Escucha SMS y notificaciones de apps bancarias, detecta si el mensaje es una transacción (monto, banco, comercio, ingreso o egreso), descarta códigos OTP y publicidad, y sube las filas a Supabase.
- `Visualizador/`: servidor local en Python (solo librería estándar) + `index.html`. Muestra los gastos por categoría y por mes, permite corregir transacciones mal leídas y marcar transferencias entre cuentas propias.
- `extraer.py`: alternativa por cable, saca la base del celular con adb y la convierte a CSV.
- `SUPABASE_SETUP.sql`: tabla de sincronización. La key pública solo puede insertar, no leer.

## Para usarlo

1. Crea un proyecto en Supabase y corre `SUPABASE_SETUP.sql`.
2. En `Capturador/.../Sync.kt` pon tu URL y tu publishable key, y compila el APK.
3. Para el visualizador, crea `Visualizador/supabase_config.json` con tu URL y tu service key (nunca la subas) y corre `python Visualizador/app.py`.

No incluye datos: ni bases, ni CSV, ni configuraciones personales.
