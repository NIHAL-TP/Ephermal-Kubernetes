const express = require("express");
const axios = require("axios");

const app = express();
const WIKI_UA = "SimpleNodeApp/1.0 (contact: example@email.com)";

// View engine
app.set("view engine", "ejs");

// Home
app.get("/", (req, res) => {
  res.render("index");
});

// Wikipedia fetch helper
async function fetchWikiSummary(query) {
  const url = `https://en.wikipedia.org/api/rest_v1/page/summary/${encodeURIComponent(query)}`;

  const { data } = await axios.get(url, {
    headers: { "User-Agent": WIKI_UA }
  });

  if (data.type === "disambiguation") {
    const error = new Error("Ambiguous search");
    error.code = 400;
    throw error;
  }

  return {
    title: data.title,
    description: data.description,
    extract: data.extract,
    thumbnail: data.thumbnail?.source || null,
    page: data.content_urls.desktop.page
  };
}

// Search route
app.get("/index", async (req, res) => {
  const query = req.query.person?.trim();

  if (!query) {
    return res.status(400).send("Search query missing");
  }

  try {
    const result = await fetchWikiSummary(query);
    res.render("result", { data: result });
  } catch (err) {
    if (err.code === 400) {
      return res.status(400).send(
        "Ambiguous search. Try a more specific name (e.g. Cristiano Ronaldo)."
      );
    }

    console.error(err.message);
    res.status(404).send("Wikipedia page not found");
  }
});

// Global 404
app.use((req, res) => {
  res.status(404).send("404: Page not found");
});

// Server
const PORT = process.env.PORT || 5000;
app.listen(PORT, () => {
  console.log(`🚀 Server running on port ${PORT}`);
});
