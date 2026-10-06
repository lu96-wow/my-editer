#lang racket

(require racket/path
         "../../../core/editor.rkt"
         "../state.rkt"
         "core.rkt"
         "../panes.rkt"
         "../edit-panes.rkt"
         "../paths.rkt"
         "../../base/wrap.rkt"
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
;;;
;;; 自动补全：命令层在每次「输入 / 退格 / 删除」后调 app-complete-refine!，
;;; 于是补全弹层随打字自动出现 / 更新，不再需要先按 Tab。弹层只截获
;;; 上/下/Enter/Esc（见 config/keys.rkt 的 complete-keys），其余按键一律
;;; 落回普通编辑表 → **不阻塞输入**。
;;;
;;; 候选池（基础命名空间 + require 导出 + 本地定义）一次补全会话只建一次，
;;; 之后的每个字符只 filter-pool；否则大文件每个字符都重解析会很卡。

;; 选中候选的 bluebox 文档（#f = 没有）。
(define (cand-doc cands i mods)
  (and (< i (length cands)) (docs-for (list-ref cands i) #:modules mods)))

;; 前缀起点（point）：光标左侧 string-length prefix 个字符。
(define (prefix-start p prefix)
  (point (point-line p) (max 0 (- (point-column p) (string-length prefix)))))

;; 当前编辑 view 的 (vid . text)；不解析 require（refine 热路径用）。
(define (app-edit-view+text a)
  (define ed (app-ed a))
  (define vid (app-focus a))
  (and vid (edit-panes-contains? (app-edit a) vid)
       (cons vid (editor-view-string ed vid))))

;; 建一次候选池：解析 require / 本地定义（贵；由 session 复用）。
(define (build-pool text mods0)
  (define mods (context-modules mods0))
  (values mods (completion-pool #:modules mods #:locals (source-definitions text))))

;; 显式触发（Tab / Ctrl+N）：前缀为空也允许（拉全量候选），并取选中项文档。
(define (app-complete-begin! a tables)
  (define ctx (app-text-context a))
  (when ctx
    (define-values (vid text mods0) (apply values ctx))
    (define-values (mods pool) (build-pool text mods0))
    (define ed (app-ed a))
    (define p (editor-view-point ed vid))
    (define prefix (prefix-at text (point-line p) (point-column p)))
    (define cands (filter-pool pool prefix))
    (when (pair? cands)
      (app-mode-set!
       a (complete-begin cands 0 (prefix-start p prefix) vid tables mods pool
                          (cand-doc cands 0 mods))))))

;; 自动过滤：前缀为空 / 无候选 → 退出补全。
;; 已有会话（同一个 view）则复用池；否则建池（每个词第一次）。
;; ⚠ 自动路径不查文档：docs-for 首次可能几十毫秒，逐字查会阻塞输入；
;;   文档在显式 Tab / 上下选择时才取（app-complete-begin! / app-complete-move!）。
(define (app-complete-refine! a tables)
  (define et (app-edit-view+text a))
  (cond
    [(not et) (app-complete-cancel! a)]
    [else
     (define vid (car et))
     (define text (cdr et))
     (define ed (app-ed a))
     (define p (editor-view-point ed vid))
     (define prefix (prefix-at text (point-line p) (point-column p)))
     (define m (app-mode a))
     (define reuse? (and (complete? m) (eqv? (complete-prev-focus m) vid)))
     (define-values (mods pool)
       (cond
         [reuse? (values (complete-mods m) (complete-pool m))]
         [else (define ctx (app-text-context a))
               (if ctx
                   (build-pool (cadr ctx) (caddr ctx))
                   (values '() '()))]))
     (define cands (and (positive? (string-length prefix)) (filter-pool pool prefix)))
     (if (pair? cands)
         (app-mode-set!
          a (complete-begin cands 0 (prefix-start p prefix) vid tables mods pool #f))
         (app-complete-cancel! a))]))

(define (app-complete-move! a delta)
  (define m (app-mode a))
  (when (complete? m)
    (define cands (complete-candidates m))
    (define n (length cands))
    (when (positive? n)
      (define i (modulo (+ (complete-index m) delta) n))
      (app-mode-set! a (struct-copy complete m
                                    [index i]
                                    [doc (cand-doc cands i (complete-mods m))])))))

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
