#lang racket

;;; ============================================================================
;;; tree.rkt —— 文件树组件：把各块接成一个 core 组件
;;; ============================================================================
;;;
;;; 文件树按职责拆成几块，各自独立、可单独测：
;;;
;;;   tree-files.rkt    磁盘动作（列目录 / 唯一名 / 建 / 删）
;;;   tree-model.rkt    数据模型（目录树 / 展开 / 可见节点 / 行↔节点 / 提示数据）
;;;   tree-project.rkt  投影（模型 + 只读 view 信息 → 普通 core 文档）
;;;   tree-prompt.rkt   提示状态机（输入 / 退格 / 取消 / 确认 + 文件动作）
;;;   tree-input.rkt    输入分发（键 / 鼠标 → 模型变换 + effects）
;;;
;;; 本文件只做两件事：
;;;   1) 把 state 的只读 ctx 适配成投影用的 tree-view；
;;;   2) 暴露组件的 sync / input / pointer，供 init 的 pane 表挂载。
;;;
;;; 规则不变：**一行一项**；树就是一个普通 core 文档；需要动全局结构时只返回 effect。

(require "state.rkt"
         "tree-model.rkt"
         "tree-project.rkt"
         "tree-input.rkt")

(provide (struct-out tree)
         tree-open
         tree-mode
         tree-lines
         tree-line-entry
         tree-line-vid
         tree-sync
         tree-input
         tree-pointer)

;;; ---------- ctx → 投影输入 ----------

(define (ctx->tree-view ctx)
  (tree-view (ctx-editor ctx) (ctx-editor-vid ctx) (ctx-pane-w ctx) (ctx-pane-h ctx)
             (ctx-opened ctx) (ctx-open-views ctx) (ctx-shown-views ctx)))

;;; ---------- 组件接口 ----------

(define (tree-sync ctx st) (tree-render (ctx->tree-view ctx) st))
(define (tree-input ctx st in) (handle-input ctx st in))
(define (tree-pointer ctx st in lr lc) (handle-pointer ctx st in lr lc))

;; 视图模式第 line 行对应的 vid（读 ctx 的已打开视图表）。
(define (tree-line-vid ctx line)
  (tree-open-view-vid (ctx-open-views ctx) line))

;;; ============================================================================
;;; 测试（直接喂 ctx，证明树不依赖 app）
;;; ============================================================================

(module+ test
  (require rackunit
           "../core/editor.rkt"
           "../core/text/document.rkt"
           "../core/text/base/point.rkt"
           "input.rkt")

  (define (k name) (key name modifiers-none))

  (define d (make-temporary-file "rbtree-~a" 'directory))
  (define f (build-path d "a.txt"))
  (display-to-file "hello\n" f #:exists 'replace)
  (make-directory (build-path d "sub"))

  ;; 一个只带 tree 视图的 editor + 手搭的只读 ctx。
  (define ed0 (editor-open "" 10 6 #:line-numbers? #t))
  (define-values (ed1 _did tvid) (editor-add-document-view ed0 "" 10 6 "*tree*" #:line-numbers? #f))
  (define (mk-ctx #:opened [opened (hash)] #:open-views [ov '()] #:shown [sh '()] #:editor-vid [ev 0])
    (ctx 0 tvid 10 6 ed1 1 ev 0 sh ov opened #f #f))
  (define C (mk-ctx))

  ;; 投影一次（模仿 project!：把文档写回 + 落光标）
  (define (run ctx st)
    (define-values (doc st* cur) (tree-sync ctx st))
    (editor-view-assign! (ctx-editor ctx) (ctx-vid ctx) doc)
    (when cur (editor-view-set-point! (ctx-editor ctx) (ctx-vid ctx) cur))
    st*)
  (define (feed ctx st in)
    (define-values (st* _eff) (tree-input ctx st in))
    (run ctx st*))
  (define (doc-string st)
    (editor-view-string ed1 tvid))

  ;; 结构行：文件夹 / 文件都每层 2 格；一行一项
  (define st0 (run C (tree-open d)))
  (check-equal? (tree-lines (tree-open d)) (list (path->string d) "sub" "a.txt"))
  (check-equal? (length (string-split (doc-string st0) "\n")) 3)

  ;; face：根（橙）/ 文件夹 / 未打开文件 / 已打开文件
  (define doc0 (editor-view-document ed1 tvid))
  (check-eq? (document-highlight-at doc0 0 0) 'tree-root)     ; 根
  (check-eq? (document-highlight-at doc0 1 0) 'tree-dir)      ; sub
  (check-eq? (document-highlight-at doc0 2 0) 'tree-file)     ; a.txt（未打开）
  (define st0b (run (mk-ctx #:opened (hash f 99)) (tree-open d)))
  (check-eq? (document-highlight-at (editor-view-document ed1 tvid) 2 0) 'tree-open)

  ;; 回车开文件 → effect，不自己动全局
  (define stF (feed C (run C (tree-open d)) (k 'down)))   ; 到 sub
  (define stF2 (feed C stF (k 'down)))                     ; 到 a.txt
  (define-values (_st eff) (tree-input C stF2 (k 'enter)))
  (check-equal? eff (list (list 'open f)))

  ;; 展开目录（回车在 sub 上）
  (define stD (feed C stF (k 'enter)))
  (check-true (regexp-match? #rx"sub" (doc-string stD)))

  ;; 新建文件：n → **手敲字符** → 回车（字符走 key 路径，paste 走 text 路径）
  (define stP (feed C (run C (tree-open d)) (k #\n)))
  (check-true (regexp-match? #rx"新建文件" (doc-string stP)))
  (define stP2 (feed C stP (k #\x)))
  (define stP3 (feed C stP2 (k #\y)))
  (check-true (regexp-match? #rx"新建文件: xy" (doc-string stP3)))
  (define stP4 (feed C stP3 (k 'backspace)))
  (check-true (regexp-match? #rx"新建文件: x" (doc-string stP4)))
  (define stP5 (feed C stP3 (k 'enter)))
  (check-true (file-exists? (build-path d "xy")))
  (check-false (regexp-match? #rx"新建文件" (doc-string stP5)))
  (check-true (for/or ([l (in-list (tree-lines stP5))]) (string-suffix? l "xy")))

  ;; 删除：定位到 xy → d → y（key） → 回车；父目录刷新
  (define xy (build-path d "xy"))
  (define line (tree-line-of stP5 xy))
  (editor-view-set-point! ed1 tvid (point line 0))
  (define stQ (feed C stP5 (k #\d)))
  (check-true (regexp-match? #rx"删除" (doc-string stQ)))
  (define stQ2 (feed C stQ (k #\y)))
  (define stQ3 (feed C stQ2 (k 'enter)))
  (check-false (file-exists? xy))
  (check-false (for/or ([l (in-list (tree-lines stQ3))]) (string-suffix? l "xy")))

  ;; ---------- 视图模式 ----------
  (define ved0 (editor-open "" 10 6 #:line-numbers? #t))
  (define-values (ved1 _vtdid vtvid) (editor-add-document-view ved0 "" 10 6 "*tree*" #:line-numbers? #f))
  (define-values (ved2 vfdid vfv) (editor-add-document-view ved1 "hello\n" 20 5 "a.txt" #:line-numbers? #t))
  (define-values (ved3 vfv2) (editor-add-view ved2 vfdid 20 5 'free #f #:line-numbers? #t))
  (define VC (ctx 0 vtvid 10 6 ved3 1 vfv 0 (list vfv vfv2) (list vfv vfv2) (hash) #f #f))
  (define (vrun st)
    (define-values (doc st* cur) (tree-sync VC st))
    (editor-view-assign! (ctx-editor VC) (ctx-vid VC) doc)
    (when cur (editor-view-set-point! (ctx-editor VC) (ctx-vid VC) cur))
    st*)
  (define (vfeed st in)
    (define-values (st* _e) (tree-input VC st in))
    (vrun st*))
  (define vs (vfeed (tree-open d) (k #\v)))
  (check-eq? (tree-mode vs) 'views)
  (check-equal? (tree-structure-count* (ctx->tree-view VC) vs) 2)
  (check-equal? (tree-line-vid VC 0) vfv)
  (check-equal? (tree-line-vid VC 1) vfv2)
  ;; face：当前编辑格视图 / 其他窗格视图
  (check-eq? (document-highlight-at (editor-view-document ved3 vtvid) 0 0) 'tree-view-active)
  (check-eq? (document-highlight-at (editor-view-document ved3 vtvid) 1 0) 'tree-view)
  ;; 回车选 vfv2 → focus-view effect
  (define-values (_vs2 eff2) (tree-input VC (vfeed vs (k 'down)) (k 'enter)))
  (check-equal? eff2 (list (list 'focus-view vfv2)))
  ;; v 切回文件
  (check-eq? (tree-mode (vfeed vs (k #\v))) 'files)

  (delete-directory/files d)
  (displayln "lab/tree.rkt: all tests passed"))
