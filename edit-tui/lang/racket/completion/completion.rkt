#lang racket

;;; edit-tui/lang/racket/completion.rkt —— Racket 补全候选（纯 / 同步 API）
;;;
;;; 这层只产出“候选字符串”，不碰 UI、键表、焦点。编辑器 / 异步 job 负责：
;;;   · 什么时候调用；
;;;   · 是否放到 worker；
;;;   · 弹出菜单、接受候选后如何插入。
;;;
;;; 共享资源：
;;;   source.rkt       #lang / require / define / provide 扫描
;;;   pool.rkt         require spec -> 最终绑定名 / 模块导出
;;;   module-index.rkt 已安装模块路径（require 补全用）
;;;   lex.rkt          本地词池
;;;
;;; 注意：module-exports 可能较慢，后续可以整体作为 worker service 的 payload。

(provide (struct-out completion-context)
         make-completion-context
         completion-prefix
         completion-at
         completion-candidates
         completion-candidates/local
         completion-candidates/required
         completion-pool
         completion-local-pool
         completion-required-pool
         completion-rank
         completion-filter
         completion-insert-text
         module-path-context?
         module-path-pool)

(require racket/list
         racket/path
         racket/string
         "../base/lex.rkt"
         "../base/keywords.rkt"
         "../parse/analysis.rkt"
         "../parse/source.rkt"
         "../parse/pool.rkt"
         "module-index.rkt"
         "../parse/workspace.rkt"
         "../base/racket.rkt")

;;; ════════════════ 上下文 ════════════════

(struct completion-context
  (path          ; string | #f
   base-dir      ; path
   lang          ; symbol | #f
   specs         ; (listof require-spec)
   open          ; hash 绝对路径字符串 -> 当前缓冲区文本
   locals        ; (listof string)：当前文件顶层定义
   bindings      ; (listof string)：按 Racket 绑定形式收集的局部名
   text          ; 当前缓冲区全文（本地词池用）
   forms         ; 已解析的模块体表单（避免重复 read）
   workspace     ; workspace | #f
   id)           ; workspace 里的当前文档 id | #f
  #:transparent)

(define (path-string p)
  (cond
    [(not p) #f]
    [(path? p) (path->string p)]
    [else (path->string (string->path p))]))

(define (base-dir-of path)
  (cond
    [(not path) (current-directory)]
    [else
     (define p (if (path? path) path (string->path path)))
     (let-values ([(d _f _n) (split-path (path->complete-path p))])
       (if (path? d) d (current-directory)))]))

;; path / text / open -> completion-context | #f
;; 不是 Racket 文件（也没有 #lang racket）时返回 #f。
;;
;; 传 #:workspace + #:id 时，优先使用 workspace 的跨 buffer 分析缓存；
;; 此时 open 映射也由 workspace 提供，调用方不需要自己拼。
(define (make-completion-context path text
                                 #:open [open (hash)]
                                 #:workspace [ws #f]
                                 #:id [id #f])
  (cond
    [(and (not (racket-file? path))
          (not (racket-text? text)))
     #f]
    [else
     (define a (and ws id (workspace-analysis ws id)))
     (define-values (lang forms specs locals bindings open*)
       (cond
         [a
          (define defs (module-analysis-definitions a))
          (values (module-analysis-lang a)
                  (module-analysis-forms a)
                  (module-analysis-specs a)
                  (for/list ([s (in-list defs)]) (symbol->string s))
                  (module-analysis-bindings a)
                  (workspace-open-texts ws))]
         [else
          (define-values (lang forms)
            (module-context text #:max-forms requires-max-forms #:max-chars requires-max-chars))
          (define specs (require-specs-of-forms lang forms))
          (define defs (definitions-of-forms forms))
          (values lang forms specs
                  (for/list ([s (in-list defs)]) (symbol->string s))
                  (local-binding-names text)
                  open)]))
     (define specs* (if (pair? specs) specs (list 'racket/base)))
     (completion-context (path-string path)
                         (base-dir-of path)
                         lang
                         specs*
                         open*
                         locals
                         bindings
                         text
                         forms
                         ws
                         id)]))

;;; ════════════════ 前缀 ════════════════

(define (line-at text line)
  (define lines (string-split text "\n" #:trim? #f))
  (if (and (exact-nonnegative-integer? line) (< line (length lines)))
      (list-ref lines line)
      ""))

;; 光标前的当前标识符前缀。Racket 标识符字符比一般语言宽，这里沿用 lex 的
;; symbol-char 判定（去掉 token 首尾限制）。
(define (completion-prefix text line col)
  (define s (line-at text line))
  (define c (min (max 0 col) (string-length s)))
  (define start
    (let loop ([i c])
      (if (and (> i 0)
               (let ([ch (string-ref s (sub1 i))])
                 (and (not (char-whitespace? ch))
                      (not (memv ch '(#\( #\) #\[ #\] #\{ #\}
                                      #\" #\; #\' #\` #\,))))))
          (loop (sub1 i))
          i)))
  (substring s start c))

;;; ════════════════ 候选池 ════════════════

(define (distinct-strings ss)
  (define seen (make-hash))
  (reverse
   (for/fold ([acc '()]) ([s (in-list ss)])
     (cond
       [(hash-ref seen s #f) acc]
       [else (hash-set! seen s #t) (cons s acc)]))))

;; 本地词池：按行扫描 token，避免整篇重复切分。
(define (local-words text)
  (define lines (string-split text "\n" #:trim? #f))
  (define token-lines (tokenize text))
  (append*
   (for/list ([line (in-list lines)] [tokens (in-list token-lines)])
     (for/list ([t (in-list tokens)]
                #:when (eq? (token-kind t) 'symbol))
       (substring line (token-start t) (token-end t))))))

(define (completion-local-pool ctx)
  (define ws (completion-context-workspace ctx))
  (define id (completion-context-id ctx))
  (cond
    ;; 有 workspace：只取“按 Racket 绑定形式解析出的本地名 + 直接 require 的
    ;; 本地 buffer 导出”。不再扫所有词，避免把注释/字符串/无关标识符塞进候选。
    [(and ws id)
     (distinct-strings
      (append (workspace-local-pool ws id)
              (hash-keys keyword-categories)))]
    [else
     (define from-current
       (append (completion-context-locals ctx)
               (completion-context-bindings ctx)
               (local-words (completion-context-text ctx))))
     (define from-open
       (append* (for/list ([text (in-list (hash-values (completion-context-open ctx)))])
                  (local-words text))))
     (distinct-strings
      (append from-current from-open
              (hash-keys keyword-categories)))]))

;; 慢：require / #lang 引入的模块导出名。
(define (completion-required-pool ctx)
  (define ws (completion-context-workspace ctx))
  (define id (completion-context-id ctx))
  (cond
    [(and ws id)
     ;; 跨 buffer：直接 require 的本地文件用 workspace 缓存，而不是重新 parse。
     (workspace-imported-names ws id)]
    [else
     (define specs (completion-context-specs ctx))
     (define base-dir (completion-context-base-dir ctx))
     (define open (completion-context-open ctx))
     (distinct-strings
      (append* (for/list ([s (in-list specs)])
                 (spec-names s base-dir open))))]))

(define (completion-pool ctx)
  (distinct-strings
   (append (completion-required-pool ctx) (completion-local-pool ctx))))

;;; ════════════════ 过滤 / 排序 ════════════════

(define (completion-filter pool prefix)
  (define plen (string-length prefix))
  (for/list ([x (in-list pool)]
             #:when (and (>= (string-length x) plen)
                         (string=? prefix (substring x 0 plen))))
    x))

;; 短的在前（同长按字典序）——让常用短名字先出现。
(define (completion-rank cands)
  (sort cands
        (lambda (a b)
          (cond [(< (string-length a) (string-length b)) #t]
                [(> (string-length a) (string-length b)) #f]
                [else (string<? a b)]))))

(define (completion-candidates ctx prefix)
  (completion-rank (completion-filter (completion-pool ctx) prefix)))

;; 只从本地池取（不加载模块），给需要快速首屏的调用方。
(define (completion-candidates/local ctx prefix)
  (completion-rank (completion-filter (completion-local-pool ctx) prefix)))

;; 只从 require / #lang 的导出取。
(define (completion-candidates/required ctx prefix)
  (completion-rank (completion-filter (completion-required-pool ctx) prefix)))

;; 候选已经包含 prefix；接受时只插入后缀。
(define (completion-insert-text candidate prefix)
  (substring candidate (min (string-length prefix) (string-length candidate))))

;;; ════════════════ require / #lang 模块路径补全 ════════════════

(define (text-before text line col)
  (define lines (string-split text "\n" #:trim? #f))
  (define n (length lines))
  (string-append
   (string-join (take lines (min line n)) "\n")
   (if (positive? line) "\n" "")
   (let ([l (if (< line n) (list-ref lines line) "")])
     (substring l 0 (min (max 0 col) (string-length l))))))

;; 最近一个未闭合 '(' 的下标；跳过字符串 / 行注释 / 块注释。
(define (last-open-paren s)
  (define n (string-length s))
  (let loop ([i 0] [stack '()] [str? #f] [esc? #f] [line-comment? #f] [blk 0])
    (cond
      [(>= i n) (and (pair? stack) (car stack))]
      [else
       (define c (string-ref s i))
       (cond
         [line-comment?
          (loop (add1 i) stack #f #f (not (char=? c #\newline)) blk)]
         [(> blk 0)
          (cond
            [(and (char=? c #\#) (< (add1 i) n) (char=? (string-ref s (add1 i)) #\|))
             (loop (+ i 2) stack #f #f #f (add1 blk))]
            [(and (char=? c #\|) (< (add1 i) n) (char=? (string-ref s (add1 i)) #\#))
             (loop (+ i 2) stack #f #f #f (sub1 blk))]
            [else (loop (add1 i) stack #f #f #f blk)])]
         [str?
          (cond
            [esc? (loop (add1 i) stack #t #f #f blk)]
            [(char=? c #\\) (loop (add1 i) stack #t #t #f blk)]
            [(char=? c #\") (loop (add1 i) stack #f #f #f blk)]
            [else (loop (add1 i) stack #t #f #f blk)])]
         [(char=? c #\") (loop (add1 i) stack #t #f #f blk)]
         [(char=? c #\;) (loop (add1 i) stack #f #f #t blk)]
         [(and (char=? c #\#) (< (add1 i) n) (char=? (string-ref s (add1 i)) #\|))
          (loop (+ i 2) stack #f #f #f 1)]
         [(memv c '(#\( #\[ #\{)) (loop (add1 i) (cons i stack) #f #f #f blk)]
         [(memv c '(#\) #\] #\})) (loop (add1 i) (if (pair? stack) (cdr stack) '()) #f #f #f blk)]
         [else (loop (add1 i) stack #f #f #f blk)])])))

(define (surface-tokens s)
  (for/list ([t (in-list (string-split s #px"[\\s()\\[\\]{}]+"))]
             #:unless (string=? t ""))
    t))

(define module-heads '(require for-syntax for-template for-label for-meta combine-in))
(define first-arg-heads '(only-in except-in rename-in prefix-in prefix-rename-in submod))

;; 光标是否处于文件开头 `#lang ` 的模块名位置。
(define (lang-context? text line col)
  (define before (text-before text line col))
  (define ln (let loop ([i (string-length before)])
               (cond [(zero? i) before]
                     [(char=? (string-ref before (sub1 i)) #\newline) (substring before i)]
                     [else (loop (sub1 i))])))
  (define n (string-length ln))
  (and (>= n 6)
       (string=? (substring ln 0 5) "#lang")
       (let ([c (string-ref ln 5)]) (or (char=? c #\space) (char=? c #\tab)))
       (for/and ([c (in-string ln 6)])
         (not (or (char-whitespace? c) (char=? c #\() (char=? c #\)))))))

;; 光标是否处于 require 的模块路径位置。
(define (require-context? text line col)
  (define before (text-before text line col))
  (define open (last-open-paren before))
  (and open
       (let* ([inside (substring before (add1 open))]
              [toks (surface-tokens inside)])
         (and (pair? toks)
              (let ([head (string->symbol (car toks))]
                    [rest (cdr toks)])
                (cond
                  [(memq head module-heads) #t]
                  [(memq head first-arg-heads) (<= (length rest) 1)]
                  [else #f]))))))

(define (module-path-context? text line col)
  (or (lang-context? text line col)
      (require-context? text line col)))

(define (module-path-pool)
  (force module-paths))

;; 高层入口：按光标上下文自动选择模块路径池或普通候选池。
;; #:workspace / #:id 传入时，补全使用跨 buffer 缓存与本地绑定。
(define (completion-at path text line col
                       #:open [open (hash)]
                       #:workspace [ws #f]
                       #:id [id #f])
  (cond
    [(module-path-context? text line col)
     (completion-filter (module-path-pool)
                        (completion-prefix text line col))]
    [else
     (define ctx (make-completion-context path text
                                         #:open open
                                         #:workspace ws
                                         #:id id))
     (if ctx
         (completion-candidates ctx (completion-prefix text line col))
         '())]))
