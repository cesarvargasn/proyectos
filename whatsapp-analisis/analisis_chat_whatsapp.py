import re
from datetime import datetime, timedelta
import pandas as pd
import matplotlib.pyplot as plt
from collections import Counter
import string

# Ruta del archivo exportado de WhatsApp
archivo = r"chat.txt"


# Leer el archivo
with open(archivo, encoding="utf-8") as f:
    chat_lines = f.readlines()

# Patrón para capturar el formato real con espacio unicode antes de "p.m." o "a.m."
pattern = r"\[(\d{1,2}/\d{1,2}/\d{2}), (\d{1,2}:\d{2}:\d{2})\u202f([ap])\.m\.\] (.*?): (.*)"
data = []

for line in chat_lines:
    match = re.match(pattern, line.strip())
    if match:
        date_str, time_str, am_pm, sender, message = match.groups()
        timestamp_str = f"{date_str} {time_str} {am_pm.upper()}M"
        try:
            dt = datetime.strptime(timestamp_str, "%m/%d/%y %I:%M:%S %p")
            data.append({"datetime": dt, "sender": sender, "message": message})
        except:
            continue

df = pd.DataFrame(data)

if not df.empty:
    # Métricas básicas
    df['time_diff'] = df['datetime'].diff().fillna(pd.Timedelta(seconds=0))
    df['new_convo'] = df['time_diff'] >= timedelta(hours=8)
    df['word_count'] = df['message'].apply(lambda x: len(x.split()))
    df['char_count'] = df['message'].apply(len)
    df['hour'] = df['datetime'].dt.hour
    df['date'] = df['datetime'].dt.date

    # Preguntas
    df['is_question'] = df['message'].apply(lambda x: "?" in x)

    # Mensajes largos
    df['is_long'] = df['word_count'] >= 30

    # Iniciadores de conversación
    df['initiator'] = df['new_convo']

    # Conteo por persona
    resumen = df['sender'].value_counts(normalize=True) * 100
    resumen = resumen.round(2).to_dict()

    print("\n📊 Porcentaje de mensajes por persona:")
    for k, v in resumen.items():
        print(f"  {k}: {v:.2f}%")

    print("\n❓ Total de preguntas por persona:")
    print(df[df['is_question']].groupby('sender').size())

    print("\n🧱 Mensajes largos (30+ palabras) por persona:")
    print(df[df['is_long']].groupby('sender').size())

    print("\n🟢 Conversaciones iniciadas (pausa ≥8h):")
    print(df[df['initiator']]['sender'].value_counts())

    # Palabras más usadas (sin signos)
    all_words = []
    for msg in df['message']:
        msg_clean = msg.translate(str.maketrans('', '', string.punctuation)).lower()
        all_words.extend(msg_clean.split())

    top_words = Counter(all_words).most_common(10)
    print("\n🔠 Palabras más usadas:")
    for word, count in top_words:
        print(f"  {word}: {count}")

    # Guardar CSV
    df.to_csv("analisis_chat_amigos.csv", index=False)

    # Gráfico de porcentaje
    plt.figure(figsize=(6, 6))
    df['sender'].value_counts(normalize=True).plot(kind='pie', autopct='%1.1f%%', startangle=90)
    plt.title("Porcentaje de mensajes por persona")
    plt.ylabel("")
    plt.tight_layout()
    plt.savefig("porcentaje_mensajes.png")
    print("\n✅ Análisis completo. Archivos guardados.")
else:
    print("⚠️ No se pudieron extraer datos. Verificá el formato del archivo.")


