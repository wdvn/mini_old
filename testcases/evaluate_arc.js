const fs = require('fs');
const path = require('path');

// Usage: node evaluate_arc.js <summary_file.json>
const summaryFile = process.argv[2];

if (!summaryFile) {
    console.error("Please provide path to ARC summary JSON. Example:");
    console.error("node evaluate_arc.js reports/arc_summary_20260919_173000.json");
    process.exit(1);
}

const summaryPath = path.resolve(summaryFile);
if (!fs.existsSync(summaryPath)) {
    console.error("File not found: " + summaryPath);
    process.exit(1);
}

let data;
try {
    data = JSON.parse(fs.readFileSync(summaryPath, 'utf8'));
} catch (e) {
    console.error("Error reading JSON file: " + e.message);
    process.exit(1);
}

console.log("==========================================================");
console.log("           ARC-AGI BENCHMARK EVALUATION RESULTS           ");
console.log("==========================================================");

let passed = 0;
let total = data.length;

data.forEach((item, index) => {
    console.log(`\n▶ Task #${index + 1}: ${item.task_id} (${item.task_name || 'ARC Puzzle'})`);
    console.log(`  Duration: ${item.duration_ms}ms`);

    const predicted = item.predicted_grid;
    const groundTruth = item.ground_truth;

    if (!predicted || !Array.isArray(predicted) || predicted.length === 0) {
        console.log("  ✗ Failed to extract valid 2D array from model output.");
        return;
    }

    if (!Array.isArray(groundTruth) || groundTruth.length === 0) {
        console.log("  ✗ Invalid ground truth data.");
        return;
    }

    const predH = predicted.length;
    const predW = Array.isArray(predicted[0]) ? predicted[0].length : 0;
    const trueH = groundTruth.length;
    const trueW = groundTruth[0].length;

    console.log(`  Predicted Dims: ${predH}x${predW} | True Dims: ${trueH}x${trueW}`);

    if (predH !== trueH || predW !== trueW) {
        console.log(`  ✗ Dimension mismatch! Expected ${trueH}x${trueW}, got ${predH}x${predW}.`);
        return;
    }

    let matchingCells = 0;
    const totalCells = trueH * trueW;

    for (let r = 0; r < trueH; r++) {
        for (let c = 0; c < trueW; c++) {
            if (predicted[r][c] === groundTruth[r][c]) {
                matchingCells++;
            }
        }
    }

    const accuracy = ((matchingCells / totalCells) * 100).toFixed(1);
    console.log(`  Cell Match: ${matchingCells}/${totalCells} (${accuracy}%)`);

    if (matchingCells === totalCells) {
        console.log("  ✅ EXACT MATCH! Puzzle solved successfully.");
        passed++;
    } else {
        console.log("  ✗ Partial match / incorrect transformation.");
        console.log("  Expected:");
        console.log(JSON.stringify(groundTruth));
        console.log("  Received:");
        console.log(JSON.stringify(predicted));
    }
});

console.log("\n==========================================================");
const scorePct = ((passed / total) * 100).toFixed(1);
console.log(`SUMMARY: ${passed} / ${total} tasks SOLVED (${scorePct}%)`);
console.log("==========================================================");
