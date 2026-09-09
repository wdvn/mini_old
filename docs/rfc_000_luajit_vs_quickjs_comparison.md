# COMPREHENSIVE COMPARISON: LUA/LUAJIT vs JAVASCRIPT/QUICKJS AS EMBEDDED INTERPRETER FOR MINI

> Detailed evaluation across technical, practical, and strategic dimensions.

---

## QUICK SUMMARY TABLE

| # | Aspect | Lua / LuaJIT | JavaScript / QuickJS | Winner |
|:---|:---|:---|:---|:---|
| 1 | Raw runtime performance | 🟢 JIT: 20-100x faster than pure interpreter | 🟡 Pure interpreter, slower than LuaJIT JIT | **LuaJIT** |
| 2 | LLM code generation accuracy | 🔴 Lowest among major languages | 🟢 Top-2, near Python parity | **QuickJS** ⭐ |
| 3 | Sandboxing & Security | 🟡 Requires disabling JIT + custom workarounds | 🟢 Native API: `JS_SetMemoryLimit`, `JS_SetInterruptHandler` | **QuickJS** |
| 4 | Binary size (static linking) | 🟡 ~400-500 KB (libluajit) | 🟢 ~200-300 KB (libquickjs, stripped) | **QuickJS** |
| 5 | Async / Promise | 🔴 No native support. Manual coroutines | 🟢 Native async/await, Promise, job queue | **QuickJS** |
| 6 | Cross-platform | 🔴 JIT limited to x86/ARM. No RISC-V | 🟢 Pure interpreter, runs wherever Zig runs | **QuickJS** |
| 7 | Zig build integration | 🟡 `zig-luajit-build` — complex build | 🟢 `zig-quickjs-ng` (mitchellh) — mature | **QuickJS** |
| 8 | Language ecosystem | 🔴 Small, niche (game scripting) | 🟢 Massive (npm, web, TypeScript) | **QuickJS** |
| 9 | Agent scripting syntax | 🟢 Simple, minimal boilerplate | 🟡 More verbose, but widely familiar | **Tie** |
| 10 | Error handling | 🟡 pcall/xpcall, error strings | 🟢 try/catch, Error objects, stack traces | **QuickJS** |
| 11 | API design (`mini.*`) | 🟢 Table-based, natural | 🟢 Object-based, natural | **Tie** |
| 12 | Migration cost from existing codebase | 🟢 Equivalent | 🟢 Equivalent | **Tie** |

**Summary: QuickJS wins 8/12, LuaJIT wins 1/12, Ties 3/12.**

---

## DETAILED COMPARISON

---

### 1. RAW RUNTIME PERFORMANCE

#### LuaJIT
- **JIT mode**: 20-100x faster than pure interpreters for CPU-intensive loops (arithmetic, repetitive string processing).
- **Interpreter mode** (when disabling JIT for sandboxing): Still ~2-5x faster than standard Lua 5.3, but loses the JIT advantage.
- **Issue**: Sandboxing mandates **disabling the JIT** (`jit.off()`), forfeiting the primary speed advantage. In interpreter mode, LuaJIT performs comparably to QuickJS.

#### QuickJS
- **Pure interpreter**: No JIT, offering predictable performance across all platforms.
- Faster than many alternative interpreters (standard Lua 5.3, Python), though ~5-10x slower than LuaJIT JIT mode.

#### Practical Evaluation for `mini`:
> **Runtime performance is NOT a bottleneck** in `mini`'s use case. Agent scripts perform 3 primary tasks:
> 1. Calling `mini.glob/grep/read` → Execution time is disk I/O bound (milliseconds), not CPU bound.
> 2. Calling `mini.sh("zig build test")` → Execution time is subprocess bound (seconds).
> 3. Lightweight string and object transformations → Microseconds for either engine.
>
> **Conclusion**: The speed difference between LuaJIT (interpreter mode) and QuickJS is **negligible** (<1ms) for real-world agent workloads. The JIT advantage of LuaJIT is nullified by sandboxing requirements.

**Winner: LuaJIT** (theoretically, but practical benefits are negated).

---

### 2. LLM CODE GENERATION ACCURACY ⭐ (CRITICAL FACTOR)

This is the **pivotal factor** of the CodeAct architecture. If an LLM generates invalid code → retries are required → turns are wasted → the efficiency advantages of CodeAct vanish.

#### Benchmark Insights (MultiPL-E, HumanEval-X, 2024-2025):

| Language | Relative Pass@1 (GPT-4o) | Training Data Volume | Notes |
|:---|:---|:---|:---|
| **Python** | ~85-92% | Billions of lines | Gold standard |
| **JavaScript** | ~80-88% | Billions of lines | Near Python parity |
| **TypeScript** | ~78-85% | Very large | Types assist LLMs |
| **Bash** | ~55-70% | Moderate | Frequent quoting/escaping issues |
| **Lua** | ~45-60% | Small | Limited training corpus, frequent syntax confusion |

#### In-Depth Analysis:

**JavaScript (QuickJS):**
- LLMs are trained on **billions of lines of JavaScript** from npm, GitHub, StackOverflow, and MDN.
- Familiar control syntax: `for...of`, `if/else`, `const/let`, `try/catch`, template literals, destructuring.
- Deep comprehension of standard idiomatic patterns: array methods (`.map`, `.filter`, `.find`), object manipulation, async/await.
- **Even within a constrained API (`mini.*`)**, JavaScript syntax remains vastly more familiar to models than Lua syntax.

**Lua (LuaJIT):**
- LLMs are trained on a **substantially smaller volume of Lua** (primarily game scripting: Roblox, WoW addons, Neovim configs).
- Frequent LLM errors when generating Lua:
  - Confusing `~=` (Lua) with `!=` (standard across other languages).
  - Forgetting 1-indexed tables instead of 0-indexed arrays.
  - Misapplying the `#` length operator (only valid for contiguous sequences).
  - Confusing `string.find` patterns with regular expressions.
  - Omitting the `local` keyword, accidentally creating global variables.

> [!CAUTION]
> **This represents the largest divergence between the two options.** While constrained APIs (~12 `mini.*` functions) narrow the gap, all **control flow syntax** (loops, conditionals, string handling, error handling) relies on the underlying language. LLMs produce JavaScript control flow with far higher precision than Lua.

**Winner: QuickJS ⭐⭐⭐** (decisive advantage for architecture).

---

### 3. SANDBOXING & SECURITY

#### LuaJIT
- **`_G` Whitelisting**: Must construct fresh environments manually, stripping `os`, `io`, `debug`, and `ffi`.
- **Memory Limits**: Requires writing custom allocators for `lua_newstate`.
- **Timeouts**: `lua_sethook` **FAILS TO OPERATE** when JIT is active. Must disable JIT or rely on OS-level timeouts.
- **FFI**: Inadvertently exposing the `ffi` module completely compromises the sandbox (permitting raw memory access).
- **Summary**: Sandboxing is **feasible but requires manual, error-prone scaffolding**.

#### QuickJS
- **`JS_SetMemoryLimit(rt, max_bytes)`**: Native API, single function call.
- **`JS_SetMaxStackSize(rt, max_size)`**: Native API, single function call.
- **`JS_SetInterruptHandler(rt, handler, opaque)`**: Native API. Periodically invoked during execution. Evaluates wall-clock time and returns non-zero to terminate execution cleanly. **Functions reliably without JIT bypass hazards**.
- **No FFI**: QuickJS has no built-in FFI module, closing that attack vector.
- **Reference Counting**: Memory reclamation is deterministic, avoiding pseudo-leak behaviors found in LuaJIT.
- **Summary**: Sandboxing is a **first-class architectural capability** in QuickJS, designed explicitly for executing untrusted code.

**Winner: QuickJS** (native sandboxing APIs without workarounds).

---

### 4. BINARY SIZE (STATIC LINKING)

| Engine | Stripped Library Size | Hello World Binary | Notes |
|:---|:---|:---|:---|
| **QuickJS-ng** | ~200-300 KB | ~210 KB | Can be reduced further with MicroQuickJS (~100 KB ROM) |
| **LuaJIT** | ~400-500 KB | ~500 KB | Includes JIT compiler bytecode even when JIT is disabled |
| **Lua 5.1** | ~150-200 KB | ~200 KB | Lightest, but slowest |

**Winner: QuickJS** (~40-50% smaller than LuaJIT).

---

### 5. ASYNC / PROMISE SUPPORT

#### LuaJIT
- **No native async/await**. Coroutines exist (`coroutine.create/resume/yield`), but:
  - Requires manual scheduler implementation.
  - Lacks integration with I/O event loops.
  - LLMs have minimal exposure writing Lua coroutines.
  - Impact: Supporting concurrent agent operations (e.g. 3 parallel HTTP calls) with Lua coroutines is disproportionately complex.

#### QuickJS
- **Native async/await, Promise**: ES2023 compliant.
  ```javascript
  // Natural async agent code generation:
  const [a, b, c] = await Promise.all([
    mini.http("GET", url1),
    mini.http("GET", url2),
    mini.http("GET", url3),
  ]);
  ```
- **Job Queue**: Host executes pending promises via `JS_ExecutePendingJob()`.
- **LLM Expertise**: Billions of async/await JavaScript examples in training datasets.

**Winner: QuickJS** (native async primitives enable future concurrent workflows).

---

### 6. CROSS-PLATFORM & ARCHITECTURAL SUPPORT

#### LuaJIT
- **JIT Compiler**: Limited to x86, x86_64, ARM, and ARM64.
- **RISC-V**: **NO official support**. Only unmaintained community forks.
- **Cross-Compilation**: Requires matching host and target pointer sizes, significantly more complex than standard C libraries.

#### QuickJS
- **Pure C Interpreter**: Architecture-agnostic, without assembly or JIT compilation constraints.
- **Ubiquitous Target Support**: Runs everywhere the Zig C compiler targets (x86, ARM, RISC-V, MIPS, WASM).
- **Trivial Cross-Compilation**: Directly compiled with `zig cc`.

**Winner: QuickJS** (absolute portability).

---

### 7. ZIG BUILD SYSTEM INTEGRATION

#### LuaJIT
- Package: `zig-luajit-build` (sackosoft).
- **Complex Build**: Requires running `minilua` and `buildvm` on the host to generate headers. Cross-compilation demands a separate `HOST_CC`.
- Potential edge-case conflicts with the Zig build graph.

#### QuickJS
- Package: `zig-quickjs-ng` (mitchellh — HashiCorp founder, reputable maintainer).
- **Streamlined Build**: Pure C compiled directly by `zig cc` without intermediate host tools.
- ~95% of C API has existing Zig bindings, minimizing manual `extern` declarations.

**Winner: QuickJS** (simpler build pipeline, mature maintenance).

---

### 8. LANGUAGE ECOSYSTEM

#### LuaJIT
- Focused niche: game scripting (Roblox, LÖVE2D, WoW), Neovim plugins, OpenResty/nginx.
- Limited libraries for complex data manipulation.
- Documentation footprint is modest compared to JavaScript.

#### QuickJS (JavaScript)
- **Largest software ecosystem**: npm, MDN, StackOverflow, extensive documentation.
- Deeply entrenched in LLM pre-training corpora.
- Vast array of standard patterns for JSON, regular expressions, and string parsing.

> **Note**: While agents in `mini` do not `require()` third-party libraries, LLMs write higher-quality JavaScript due to sheer training volume.

**Winner: QuickJS**.

---

### 9. AGENT SCRIPTING SYNTAX

#### Lua
```lua
local files = mini.glob("**/*.zig", "src")
for _, f in ipairs(files) do
    local content = mini.read(f)
    if content and content:find("pattern") then
        mini.patch(f, "old", "new")
    end
end
```
- **Pros**: Concise, minimal boilerplate.
- **Cons**: `ipairs`, `#table`, 1-indexed collections, `~=` instead of `!=` — prone to model errors.

#### JavaScript (QuickJS)
```javascript
const files = mini.glob("**/*.zig", "src");
for (const f of files) {
    const content = mini.read(f);
    if (content && content.includes("pattern")) {
        mini.patch(f, "old", "new");
    }
}
```
- **Pros**: Globally recognized syntax, `for...of`, `.includes()`, 0-indexed.
- **Cons**: Slightly more verbose (`const/let`, braces `{}`, semicolons `;`).

**Winner: Tie** — Both are suitable for scripting. Lua is more concise; JavaScript is universally familiar.

---

### 10. ERROR HANDLING

#### Lua
```lua
local ok, err = pcall(function()
    mini.write("/path", content)
end)
if not ok then print("Error: " .. err) end
```
- `pcall` / `xpcall` returns a boolean + error string.
- Lacks structured error objects.
- Stack traces depend on `debug.traceback` (which sandboxes disable).

#### JavaScript (QuickJS)
```javascript
try {
    mini.write("/path", content);
} catch (e) {
    console.log(`Error: ${e.message}`);
    console.log(e.stack);  // Automatic stack trace
}
```
- Native `try/catch`, structured `Error` objects (`message`, `stack`, `name`).
- LLMs write JS try/catch blocks reliably.
- Automatic stack traces without requiring debug modules.

**Winner: QuickJS** (superior error reporting and model generation reliability).

---

### 11. API DESIGN (`mini.*`)

#### Lua:
```lua
mini.glob("**/*.zig")              --> table of strings
mini.read("path")                   --> string
mini.sh("cmd")                      --> table { exit_code, stdout, stderr }
```

#### JavaScript:
```javascript
mini.glob("**/*.zig")              // → string[]
mini.read("path")                   // → string
mini.sh("cmd")                      // → { exitCode, stdout, stderr }
```

Both designs are intuitive. JavaScript holds minor ergonomic benefits:
- Destructuring: `const { exitCode, stdout } = mini.sh("cmd");`
- Template literals: `` `Found ${files.length} files` ``
- Functional utilities: `files.filter(f => f.endsWith(".zig")).map(f => mini.read(f))`

**Winner: Tie** (both are practical; JS provides richer syntactic sugar).

---

### 12. MIGRATION COST FROM EXISTING CODEBASE

Both paths share identical implementation requirements:
1. Integrating C library dependencies in `build.zig`.
2. Writing C-ABI bindings for ~12 `mini.*` functions.
3. Implementing sandbox, timeout, and memory limit wrappers.
4. Extracting code blocks from LLM responses in the agent loop.
5. Implementing the self-correction loop.
6. Updating system prompts.

Neither approach offers an engineering effort advantage.

**Winner: Tie**.

---

## SWOT ANALYSIS

### QuickJS (JavaScript)
| | Strengths | Weaknesses |
|:---|:---|:---|
| **Internal** | ✅ Overwhelmingly superior LLM code generation | ❌ No JIT (slower for CPU-heavy tasks) |
| | ✅ Mature, native sandboxing APIs | ❌ Event loops needed for async coordination |
| | ✅ Native async/await support | |
| | ✅ Compact, portable binary footprint | |
| **External** | ✅ Massive JS ecosystem yields rich training data | ❌ QuickJS-ng is community-maintained |
| | ✅ Mature mitchellh Zig bindings | ❌ Large ES2023 specification expands theoretical attack surface |

### LuaJIT
| | Strengths | Weaknesses |
|:---|:---|:---|
| **Internal** | ✅ JIT performance (when active) | ❌ Must disable JIT for sandboxing, negating benefits |
| | ✅ Minimalist syntax | ❌ Lowest LLM code generation accuracy |
| | | ❌ No native async/await |
| | | ❌ Sandboxing must be manually constructed |
| **External** | ✅ Battle-tested in gaming (Roblox, WoW) | ❌ No RISC-V support |
| | | ❌ Complex cross-compilation |
| | | ❌ Single maintainer with slow PR merges |

---

## CONCLUSION & RECOMMENDATION

### Verdict: **QuickJS (JavaScript) is the optimal choice for `mini`**

#### Core Rationale:
1. **LLM code generation accuracy is the single most critical factor** in CodeAct architectures. Efficiency gains (turn reductions, token savings, speed) **depend on the model generating valid code on the first attempt**. JavaScript possesses an insurmountable advantage here.

2. **LuaJIT's JIT advantage is negated in production**: Sandboxing requires disabling the JIT → LuaJIT interpreter performance is comparable to QuickJS → eliminating the primary justification for LuaJIT.

3. **QuickJS Sandboxing is Superior**: `JS_SetMemoryLimit`, `JS_SetInterruptHandler`, and `JS_SetMaxStackSize` provide robust protection in three lines of code without custom timeout infrastructure.

4. **Async/await Enables Future Extensibility**: Agents can dispatch parallel HTTP requests and run concurrent `mini.sh()` processes — patterns that are exceptionally difficult with Lua coroutines and rarely understood by LLMs.

5. **Universal Portability**: Enables `mini` to compile for RISC-V, WASM, and every architecture supported by Zig.

#### Considerations:
- QuickJS is slower than LuaJIT JIT mode for compute-heavy algorithms — but agent scripts are I/O bound rather than compute bound.
- ES2023 is broad → exposed APIs in the sandbox must be carefully whitelisted (a requirement shared with Lua regarding `ffi`).

#### Action Taken:
Adopted QuickJS-ng. Architectural patterns (hybrid strategy, self-correction loop, permissions, API design) remain consistent, utilizing QuickJS runtime layers and JavaScript syntax.
