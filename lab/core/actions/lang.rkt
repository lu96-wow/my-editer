#lang racket

(require racket/path
         (only-in racket/string string-split string-trim)
         "../../../core/editor.rkt"
         "../state.rkt"
         "core.rkt"
         "../panes.rkt"
         "../edit-panes.rkt"
         "../paths.rkt"
         "../../ui/mode.rkt"
         "../../lang/ident.rkt"
         "../../lang/source.rkt"
         "../../lang/docs.rkt"
         "../../lang/complete.rkt")

;;; lab-rebuild/core/actions/lang.rkt —— 语言服务动作（文档查询 / 补全）
;;;
;;; 纯逻辑在 lang/ 下（ident / source / docs / complete），本文件只把它们接到 app：
;;;   · 文档查询：取光标处标识符 → 查文档 → 进 docs 浮窗（Enter/Esc 关，上下滚）
;;;   · 补全：取光标左侧前缀 → 候选 → 进 complete 模态；弹层渲染在 app/render.rkt
;;;
;;; 两个浮层都不碰 editor、不动焦点；只改 mode。补全接受产生的 change 由
;;; command/registry 交给插件层（core 不 require 插件）。

(provide app-show-docs! app-docs-close! app-docs-scroll!
         app-complete-begin! app-complete-refine!
         app-complete-move! app-complete-cancel! app-complete-accept!)

;;; ================= 公共：当前编辑上下文 =================

;; 焦点在编辑窗格时 → (list vid text modules)，否则 #f。
;; modules = #lang 语言 + 各 require 解析出的模块路径（lang/source）。
(define (app-text-context a)
  (define ed (app-ed a))
  (define vid (app-focus a))
  (and vid
       (edit-panes-contains? (app-edit a) vid)
       (let* ([did (editor-view-document-id ed vid)]
              [path (path-table-path (app-paths a) did)]
              [base-dir (if path (let-values ([(d _n _m) (split-path path)]) d) (current-directory))]
              [text (editor-view-string ed vid)])
         (list vid text (source-requires text #:base-dir base-dir)))))

;; 查文档/补全时统一再补两个兜底模块（语言模块可能漏掉内置）。
(define (context-modules mods)
  (remove-duplicates (append mods '(racket racket/base)) equal?))

;;; ================= 文档查询（浮窗） =================

;; 单行按内容宽 w 折行：尽量在空格断，断不了就硬断。
(define (wrap-line s w)
  (let loop ([s s] [acc '()])
    (cond
      [(<= (string-length s) w) (reverse (cons s acc))]
      [else
       (define cut
         (or (for/first ([i (in-range (sub1 w) 0 -1)]
                         #:when (char=? (string-ref s i) #\space))
               i)
             w))
       (loop (string-trim (substring s cut)) (cons (substring s 0 cut) acc))])))

(define (wrap-lines text w)
  (append* (for/list ([l (in-list (string-split text "\n"))]) (wrap-line l w))))

;; 取文档 → 折成浮窗内容行 → 进 docs 模态。
(define (app-show-docs! a tables)
  (define ctx (app-text-context a))
  (when ctx
    (define-values (vid text mods) (apply values ctx))
    (define ed (app-ed a))
    (define p (editor-view-point ed vid))
    (define id (identifier-at text (point-line p) (point-column p)))
    (define body
      (cond
        [(not id) "（光标处没有标识符）"]
        [else
         (define d (docs-for id #:modules (context-modules mods)))
         (if d (doc->text d) (format "~a\n\n（未找到文档）" id))]))
    (define w (max 20 (min 88 (- (app-width a) 6))))
    (define rows (max 1 (min 20 (- (app-height a) 4))))
    (app-mode-set! a (docs-begin vid p (list->vector (wrap-lines body w)) 0 w rows tables))))

(define (app-docs-close! a)
  (when (docs? (app-mode a)) (app-mode-set! a #f)))

(define (app-docs-scroll! a delta)
  (define m (app-mode a))
  (when (docs? m)
    (define n (vector-length (docs-lines m)))
    (define max-off (max 0 (- n (docs-rows m))))
    (app-mode-set! a
      (struct-copy docs m [offset (max 0 (min max-off (+ (docs-offset m) delta)))]))))

;;; ================= 补全 =================

(define (lang-candidates prefix locals mods)
  (completions prefix
               #:modules (context-modules mods)
               #:locals locals))

;; 前缀起点（point）：光标左侧 string-length prefix 个字符。
(define (prefix-start p prefix)
  (point (point-line p) (max 0 (- (point-column p) (string-length prefix)))))

;; 显式触发：前缀为空也允许（拉全量候选）。
(define (app-complete-begin! a tables)
  (define ctx (app-text-context a))
  (when ctx
    (define-values (vid text mods) (apply values ctx))
    (define ed (app-ed a))
    (define p (editor-view-point ed vid))
    (define prefix (prefix-at text (point-line p) (point-column p)))
    (define cands (lang-candidates prefix (source-definitions text) mods))
    (when (pair? cands)
      (app-mode-set! a (complete-begin cands 0 (prefix-start p prefix) vid tables)))))

;; 边打字边过滤：前缀为空 / 无候选 → 退出补全。
(define (app-complete-refine! a tables)
  (define ctx (app-text-context a))
  (cond
    [(not ctx) (app-complete-cancel! a)]
    [else
     (define-values (vid text mods) (apply values ctx))
     (define ed (app-ed a))
     (define p (editor-view-point ed vid))
     (define prefix (prefix-at text (point-line p) (point-column p)))
     (define cands (and (positive? (string-length prefix))
                        (lang-candidates prefix (source-definitions text) mods)))
     (if (pair? cands)
         (app-mode-set! a (complete-begin cands 0 (prefix-start p prefix) vid tables))
         (app-complete-cancel! a))]))

(define (app-complete-move! a delta)
  (define m (app-mode a))
  (when (complete? m)
    (define n (length (complete-candidates m)))
    (when (positive? n)
      (app-mode-set! a (struct-copy complete m [index (modulo (+ (complete-index m) delta) n)])))))

(define (app-complete-cancel! a)
  (when (complete? (app-mode a)) (app-mode-set! a #f)))

;; 接受当前候选：把 [start, 光标) 换成候选名。返回 (list changes vid) 或 #f；
;; 用户改了编辑器值的动作返回 change，由命令层交给插件层（core 不 require 插件）。
(define (app-complete-accept! a)
  (define m (app-mode a))
  (and (complete? m)
       (let* ([cand (list-ref (complete-candidates m) (complete-index m))]
              [vid (complete-prev-focus m)]
              [ed (app-ed a)]
              [p (editor-view-point ed vid)]
              [start (complete-start m)])
         (app-mode-set! a #f)
         (editor-view-set-selections! ed vid (selections-one (selection start p)))
         (define-values (changes _ok?) (editor-view-insert! ed vid cand))
         (list changes vid))))
