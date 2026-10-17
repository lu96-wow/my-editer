#lang racket

;;; edit-tui-rebuild/test/layers.rkt —— 架构约束的机器检查
;;;
;;; 这不是行为测试，而是把“分层”从口头约定变成断言。四条规则：
;;;
;;;   1. 每个模块开头必须声明 `;;; layer  :` 与 `;;; effect :`
;;;      —— 副作用无法悄悄混进来；
;;;   2. `(require ...)` 的边必须符合层序 DAG
;;;      —— base < model < env < effects < projection < dispatch < chrome <
;;;         bootstrap < plugins < runtime；
;;;   3. 允许 require `core/...` 的模块是白名单
;;;      —— core 只出现在引擎 / 投影 / 面板装配 / 命令原语处；
;;;   4. 允许做文件系统 IO 的模块是白名单
;;;      —— 插件投影分成 scan（IO）与 lines（纯）。
;;;
;;; 违反时直接 check-* 失败并打印文件名，方便定位。
;;;
;;; 运行：racket edit-tui-rebuild/test/layers.rkt

(require rackunit
         racket/list
         racket/path
         racket/string)

;;; ════════════════ 工程根 / 文件枚举 ════════════════

;; 本文件在 <root>/test/layers.rkt。
;; 用模块自身的路径定位（不依赖 cwd，也不依赖“是脚本还是被 require”）。
(define module-path
  (resolved-module-path-name
   (module-path-index-resolve
    (variable-reference->module-path-index (#%variable-reference)))))
(define test-dir (path-only (path->complete-path module-path)))
(define root (simplify-path (build-path test-dir "..")))
(define (rel p) (path->string (find-relative-path root p)))

(define (rkt-files dir)
  (for/list ([p (in-directory dir)]
             #:when (and (file-exists? p)
                         (equal? (path-get-extension p) #".rkt")
                         (not (member "compiled" (map path->string (explode-path p))))))
    p))

(define impl-files
  (append (rkt-files (build-path root "base"))
          (rkt-files (build-path root "model"))
          (rkt-files (build-path root "env"))
          (rkt-files (build-path root "effects"))
          (rkt-files (build-path root "projection"))
          (rkt-files (build-path root "dispatch"))
          (rkt-files (build-path root "chrome"))
          (rkt-files (build-path root "bootstrap"))
          (rkt-files (build-path root "plugins"))
          (rkt-files (build-path root "runtime"))
          (list (build-path root "main.rkt"))))

;;; ════════════════ 极简 require 解析 ════════════════

;; 只处理“(require ...)”形式：跳过字符串与 ; 注释，数括号。
;; 返回形式里出现的字符串字面量（模块路径）列表。
(define (require-strings src)
  (define n (string-length src))
  (define out '())
  (define (skip-string i)                      ; i 指向开引号，返回结束位置
    (let loop ([i (add1 i)])
      (cond [(>= i n) i]
            [(char=? (string-ref src i) #\") (add1 i)]
            [(char=? (string-ref src i) #\\) (loop (+ i 2))]
            [else (loop (add1 i))])))
  (define (skip-comment i)                     ; 到行尾
    (let loop ([i i])
      (cond [(>= i n) i]
            [(char=? (string-ref src i) #\newline) i]
            [else (loop (add1 i))])))
  (define (word-at i w)
    (and (<= (+ i (string-length w)) n)
         (string=? (substring src i (+ i (string-length w))) w)))
  (let loop ([i 0] [depth 0] [collect? #f])
    (cond
      [(>= i n) (reverse out)]
      [(char=? (string-ref src i) #\")
       (define end (skip-string i))
       (define s (substring src (add1 i) (sub1 end)))
       (when (and collect? (> depth 0) (string-suffix? s ".rkt"))
         (set! out (cons s out)))
       (loop end depth collect?)]
      [(char=? (string-ref src i) #\;) (loop (skip-comment i) depth collect?)]
      [(and (= depth 0)
            (char=? (string-ref src i) #\()
            (let ([j (let skip ([j (add1 i)])
                       (if (and (< j n) (char-whitespace? (string-ref src j)))
                           (skip (add1 j)) j))])
              (word-at j "require")))
       (loop (+ i 8) 1 #t)]
      [(char=? (string-ref src i) #\() (loop (add1 i) (add1 depth) collect?)]
      [(char=? (string-ref src i) #\))
       (loop (add1 i) (sub1 depth) (if (zero? (sub1 depth)) #f collect?))]
      [else (loop (add1 i) depth collect?)])))

;;; ════════════════ 1. 头部声明 ════════════════

(for ([p (in-list impl-files)])
  (define src (file->string p))
  (define head (string-join (take (string-split src "\n")
                                  (min 40 (length (string-split src "\n"))))
                            "\n"))
  (check-true (regexp-match? #rx";;; layer  : " head)
              (format "缺少 `;;; layer  :` 声明：~a" (rel p)))
  (check-true (regexp-match? #rx";;; effect : " head)
              (format "缺少 `;;; effect :` 声明：~a" (rel p))))

;;; ════════════════ 2. 层序 DAG ════════════════

;; layer -> 允许它 require 的 layer 集合（含自己）
(define layers
  (hash "base"        '(base)
        "model"       '(base model)
        "env"         '(base model env)
        "effects"     '(base model effects)
        "projection"  '(base model effects projection)
        "dispatch"    '(base model env effects projection dispatch)
        "chrome"      '(base model env effects projection dispatch chrome)
        "bootstrap"   '(base model env effects projection dispatch chrome bootstrap)
        "plugins"     '(base model env effects projection dispatch chrome bootstrap plugins)
        "runtime"     '(base model env effects projection dispatch chrome bootstrap plugins runtime)
        ;; 公共面：把各层再导出，等价于“最上层”
        "main"        '(base model env effects projection dispatch chrome bootstrap plugins runtime)))

(define (layer-of path)
  ;; main.rkt 是公共面：只 require/provide，不参与层序（但没有副作用）。
  (if (regexp-match? #rx"/" path)
      (car (string-split path "/"))
      "main"))

(define external-prefixes
  ;; token 词汇（key/mouse/command 结构）与 core 引擎：任意层都可以用它（core 另行白名单）。
  '("../edit-tui/command/" "../../edit-tui/command/" "../../../edit-tui/command/"
    "../edit-tui/core-render/" "../../edit-tui/core-render/"
    "../../../core/" "../../core/"))

(define (external? s) (for/or ([p (in-list external-prefixes)]) (string-prefix? s p)))

(for ([p (in-list impl-files)])
  (define here (rel p))
  (define l (layer-of here))
  (check-true (hash-has-key? layers l) (format "未知层：~a" here))
  (for ([s (in-list (require-strings (file->string p)))])
    (unless (external? s)
      (define target (rel (simplify-path (build-path (path-only p) s))))
      (define tl (layer-of target))
      (check-true (and (hash-has-key? layers tl)
                       (memq (string->symbol tl) (hash-ref layers l))
                       #t)
                  (format "层序违规：~a (~a) -> ~a (~a)" here l target tl)))))

;;; ════════════════ 3. core 白名单 ════════════════

;; core 对象/值只应出现在：引擎（唯一拥有者）、投影（构造 rect/panel/patch）、
;; 面板装配（创建/销毁/写 buffer）、命令（effect 里的 op/point/selection 值）。
(define core-allowed
  '("effects/engine.rkt"
    "effects/interpreter.rkt"      ; set-faces / replace-range 是 core 端口的写回
    "projection/geometry.rkt"
    "projection/float.rkt"
    "projection/render.rkt"
    "effects/panel.rkt"
    "bootstrap/commands/table.rkt"
    "bootstrap/commands/focus.rkt"
    "plugins/completion/plugin.rkt"   ; replace-range / select 需要 core 的 point/range/selection 值
    "runtime/run.rkt"))

(for ([p (in-list impl-files)])
  (define here (rel p))
  (define touches-core?
    (for/or ([s (in-list (require-strings (file->string p)))])
      (regexp-match? #rx"core/" s)))
  (when touches-core?
    (check-not-false (member here core-allowed)
                (format "core 依赖不在白名单：~a" here))))

;;; ════════════════ 4. 文件系统 IO 白名单 ════════════════

(define io-rx
  ;; 只看“真的调用了”的形式：(函数名 + 空白)，并先去掉注释行 —— 免得
  ;; effect 结构名（make-directory-effect）或注释里的说明被误判。
  #rx"\\(\\s*(file->string|string->file|with-output-to-file|call-with-output-file|directory-list|file-exists\\?|directory-exists\\?|delete-file|make-directory|copy-file|rename-file-or-directory)\\s")

(define (code-only src)
  (string-join (for/list ([l (in-list (string-split src "\n"))]
                          #:unless (regexp-match? #rx"^\\s*;" l))
                 l)
               "\n"))

(define io-allowed
  '("effects/interpreter.rkt"     ; 文件读写是 effect 的语义
    "plugins/filetree/scan.rkt"   ; 读目录（面板观察者）
    "plugins/filetree/commands.rkt")) ; 建/删文件前的存在性检查

(for ([p (in-list impl-files)])
  (define here (rel p))
  (define src (file->string p))
  (when (regexp-match? io-rx (code-only src))
    (check-not-false (member here io-allowed)
                (format "文件系统 IO 不在白名单：~a" here))))

;;; ════════════════ 5. 终端 / 线程只在壳里 ════════════════

(define tui-allowed '("runtime/run.rkt"))
(define thread-allowed '("runtime/run.rkt"))

(for ([p (in-list impl-files)])
  (define here (rel p))
  (define src (file->string p))
  (when (regexp-match? #rx"\\(require tui\\)|\\bput-bytes\\b|\\bread-event\\b|\\bwith-tui\\b" src)
    (check-not-false (member here tui-allowed)
                (format "终端 IO 不在 runtime：~a" here)))
  (when (regexp-match? #rx"async-channel|\\bthread\\b" src)
    (check-not-false (member here thread-allowed)
                (format "线程 / inbox 不在 runtime：~a" here))))

;;; ════════════════ 6. 约定：信号点词表与“上色不发 after-edit” ════════════════

(require "../base/signal.rkt")

;; 标准信号点是**数据**（不是散落在代码里的 symbol）：四个点都在，
;; 且 known-signal-point? 认得它们；加新点必须同时改这份词表。
(check-equal? (sort (map symbol->string signal-points) string<?)
              '("after-edit" "after-nav" "document-opened" "focus-changed"))
(for ([p (in-list signal-points)])
  (check-true (known-signal-point? p)))
(check-false (known-signal-point? 'after-faces))

;;; ════════════════ 7. 结构快照（防止层被悄悄合并） ════════════════

;; 顶层目录 = 层；少一个/多一个都值得停下来看一眼。
(define impl-dirs
  (sort (remove-duplicates
         (for/list ([p (in-list impl-files)]
                    #:when (regexp-match? #rx"/" (rel p)))
           (layer-of (rel p))))
        string<?))
(check-equal? impl-dirs
              '("base" "bootstrap" "chrome" "dispatch" "effects" "env"
                "model" "plugins" "projection" "runtime"))
