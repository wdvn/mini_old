# 📚 ArXiv Paper Aggregator

An intelligent agent powered by `mini-agent` to query, filter, and summarize breakthrough scientific papers from arXiv, focusing on Computer Science (AI, LLMs, Computer Vision, Networking, etc.).

The system automatically extracts Atom XML data using an agent-generated Python script and outputs a structured Markdown report. The report format is tailored for Software Engineers to quickly grasp key paper findings via `TL;DR` summaries.

## 🚀 Quick Start

```bash
cd examples/arxiv
./run.sh
```

## ⚙️ Advanced Options

You can adjust the maximum number of papers fetched from the API and specify the output file path:

```bash
./run.sh --max-results 30 --output /tmp/my_arxiv_digest.md
```

## 🧠 Recommended Models

The agent requires strong reasoning capabilities and a large context window to process paper summaries. Recommended:
- `gpt-4o`
- `claude-3-5-sonnet`
- Any large reasoning model via OpenAI-compatible endpoints.

