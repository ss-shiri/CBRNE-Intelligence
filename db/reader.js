async function loadDB() {
  const container = document.getElementById("content");

  try {
    const res = await fetch("https://raw.githubusercontent.com/ss-shiri/CBRNE-Intelligence/main/db/index.json");
    if (!res.ok) throw new Error("DB not found");

    const data = await res.json();

    container.innerHTML = `
      <h1>CBRNE Intelligence Reading Room</h1>
      <p>Loaded ${data.length} records from database.</p>
      <ul>
        ${data.map(item => `
          <li>
            <strong>${item.title}</strong><br>
            <small>${item.source}</small>
          </li>
        `).join("")}
      </ul>
    `;
  } catch (err) {
    container.innerHTML = `<p style="color:red">Error loading database: ${err.message}</p>`;
  }
}

loadDB();
