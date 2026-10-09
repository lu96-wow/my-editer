#lang racket

;;; edit/plugin/builtin/completion.rkt —— 补全插件（模块路径 / 模块导出 / 本地定义 / 文档词）
;;;
;;; 菜单是**叠加层（deco）视图**（不抢焦点）；打开时压一个输入层（模态键表）：
;;;   · 上下/Enter/Tab/Esc 由层接管；
;;;   · 普通字符层里没有 → fallthrough 到文档键表 → cmd-insert → 本 handler 接手：
;;;     先插入再按新前缀从**复用池**过滤。
;;; 接受：把 [前缀起点, 光标) 换成候选。
;;;
;;; 候选池（一次会话只建一次，之后只过滤）：
;;;   · require 上下文 → 已安装模块路径（lang/module-index）；
;;;   · 否则 → #lang/require 的模块导出 + 文件顶层定义 + 文件里出现过的词（lang/pool）。
;;; 前缀走 core/lex 的 prefix-at（与高亮同一套词法）。

(require racket/list
         racket/path
         racket/string
         "../registry.rkt"
         "../../feature/api.rkt"
         "../../core/lex.rkt"
         "../../core/file-kind.rkt"
         "../../lang/source.rkt"
         "../../lang/module-index.rkt"
         "../../lang/pool.rkt")

(provide completion-install completion-spec)

;;; ---------- 菜单状态 ----------

(struct menu (vid mvid did start cands idx pool) #:transparent)
;; vid   : 编辑器 view（发起补全者，接受时改它）
;; mvid  : 菜单视图
;; did   : 发起时编辑器文档 id（关文档时以此取消菜单）
;; start : (cons line col)  前缀起点
;; cands : (listof string)  当前过滤后的候选
;; idx   : 选中下标
;; pool  : (listof string)  本次会话的完整候选池（复用）

(define max-rows 10)
(define menu-deep 2000)                            ; 远高于布局树

;;; ---------- 候选（纯） ----------

;; → (values pool cands)。require 上下文 → 模块路径；否则 → 导出 + 定义 + 文档词。
(define (candidates-for s vid text line col prefix)
  (cond
    [(zero? (string-length prefix)) (values '() '())]
    [(require-context? text line col)
     (define pool (force module-paths))
     (values pool (filter-pool pool prefix))]
    [else
     (define pool (symbol-pool s vid text))
     (values pool (filter-pool pool prefix))]))

(define (symbol-pool s vid text)
  (define did (session-view-did s vid))
  (define path (and did (session-file-path s did)))
  (define words (document-words text))
  (cond
    [(not (racket-file? path)) (distinct-strings words)]
    [else
     (define base-dir (or (and path (let-values ([(d _f _m) (split-path path)]) d))
                          (current-directory)))
     (define-values (lang forms) (requires-context text))
     (completion-pool #:modules (requires-of-forms lang forms #:base-dir base-dir)
                      #:locals (definitions-of-forms forms)
                      #:words words)]))

;;; ---------- 菜单内容 / 几何 ----------

(define (menu-doc cands idx)
  (define n (length cands))
  (define rows (min n max-rows))
  (define start (max 0 (min (- idx (quotient rows 2)) (- n rows))))
  (define shown (take (drop cands start) rows))
  (panel-doc
   (for/list ([c (in-list shown)] [i (in-naturals)])
     (list (string-append " " c)
           (if (= (+ start i) idx) 'complete-selected 'complete)))))

;; 菜单在光标下方（放不下则上方）；宽随候选，钳到屏幕内。→ (values x y w h)
(define (menu-rect s vid cands)
  (define-values (col row) (session-view-cursor-screen s vid))
  (define c (or col 0))
  (define r (or row 0))
  (define n (length cands))
  (define h (min n max-rows))
  (define want (+ 2 (for/fold ([m 0]) ([x (in-list cands)]) (max m (string-length x)))))
  (define w (min (max 10 (- (session-width s) 2)) (max 10 want)))
  (define x (max 0 (min c (- (session-width s) w))))
  (define y (if (<= (+ r 1 h) (session-height s)) (+ r 1) (max 0 (- r h))))
  (values x y w h))

;;; ---------- 打开 / 刷新 / 移动 / 接受 / 关闭 ----------

;; 每帧叠加层：菜单打开时把菜单视图摆在光标处。
(define (menu-panes s state)
  (define m (unbox state))
  (cond
    [(not m) '()]
    [else
     (define cands (menu-cands m))
     (define-values (x y w h) (menu-rect s (menu-vid m) cands))
     (list (placed (menu-mvid m) x y w h menu-deep))]))

(define (do-open s state)
  (cond
    [(unbox state) s]                              ; 已开则忽略
    [else
     (define vid (session-focus-vid s))
     (cond
       [(not vid) s]
       [else
        (define text (session-view-string s vid))
        (define line (session-view-point-line s vid))
        (define col (session-view-point-column s vid))
        (define prefix (prefix-at text line col))
        (define-values (pool cands) (candidates-for s vid text line col prefix))
        (cond
          [(null? cands) s]
          [else
           (define start (cons line (- col (string-length prefix))))
           (define-values (x y w h) (menu-rect s vid cands))
           (define-values (s1 _mdid mvid)
             (session-add-document s (menu-doc cands 0) w h #:name "*complete*"))
           (set-box! state (menu vid mvid (session-view-did s vid) start cands 0 pool))
           ;; 登记叠加 vid（dock / 不入缓冲区）+ 叠加层（几何每帧算）
           (define s2 (session-overlay-add s1 mvid))
           (define s3 (session-deco-add s2 (deco 'complete (lambda (s) (menu-panes s state)))))
           (session-layer-push s3 'complete complete-keys)])])]))

(define (do-refine s state)
  (define m (unbox state))
  (define vid (menu-vid m))
  (define text (session-view-string s vid))
  (define line (session-view-point-line s vid))
  (define col (session-view-point-column s vid))
  (define prefix (prefix-at text line col))
  (define cands (filter-pool (menu-pool m) prefix))
  (cond
    [(null? cands) (do-close s state)]
    [else
     (define idx (min (menu-idx m) (sub1 (length cands))))
     (define start (cons line (- col (string-length prefix))))
     (set-box! state (menu vid (menu-mvid m) (menu-did m) start cands idx (menu-pool m)))
     (session-ed-assign! s (menu-mvid m) (menu-doc cands idx))]))

(define (do-move s state dir)
  (define m (unbox state))
  (define n (length (menu-cands m)))
  (define idx (modulo (+ (menu-idx m) dir) n))
  (set-box! state (struct-copy menu m [idx idx]))
  (session-ed-assign! s (menu-mvid m) (menu-doc (menu-cands m) idx)))

(define (do-accept s state)
  (define m (unbox state))
  (define cand (list-ref (menu-cands m) (menu-idx m)))
  (define vid (menu-vid m))
  (define line (session-view-point-line s vid))
  (define col (session-view-point-column s vid))
  (define start (menu-start m))
  (do-close (session-ed-replace! s vid (car start) (cdr start) line col cand) state))

(define (do-close s state)
  (define m (unbox state))
  (cond
    [(not m) s]
    [else
     (set-box! state #f)
     (define mvid (menu-mvid m))
     (define did (session-view-did s mvid))
     (define s1 (session-deco-remove (session-overlay-remove s mvid) 'complete))
     (session-close-document (session-layer-pop s1 'complete) did)]))

;;; ---------- 命令 + 键 + handler ----------

(define complete-keys
  (kbd (key 'down)   (cmd-complete-move 1)
       (key 'up)     (cmd-complete-move -1)
       (key 'tab)    (cmd-complete-accept)
       (key 'enter)  (cmd-complete-accept)
       (key 'escape) (cmd-complete-cancel)))

(define (completion-state s) (session-service-ref s 'complete))

(define (completion-handler)
  (lambda (s cmd)
    (define st (completion-state s))
    (cond
      [(cmd-complete? cmd) (and st (not (unbox st)) (do-open s st))]
      [(cmd-complete-move? cmd) (and st (unbox st) (do-move s st (cmd-complete-move-dir cmd)))]
      [(cmd-complete-accept? cmd) (and st (unbox st) (do-accept s st))]
      [(cmd-complete-cancel? cmd) (and st (unbox st) (do-close s st))]
      [else #f])))

;; 改文本后刷新候选：只跟「直接编辑」（after-insert），程序写入不触发。
(define (completion-refine-hook s _args)
  (define st (completion-state s))
  (if (and st (unbox st)) (do-refine s st) s))

;; 焦点移开 → 取消菜单。
(define (completion-cancel-hook s _args)
  (define st (completion-state s))
  (if (and st (unbox st)) (do-close s st) s))

;; 菜单所属的编辑器文档关闭 → 取消菜单（避免叠加层悬空）。
(define (completion-doc-closed-hook s args)
  (define st (completion-state s))
  (define m (and st (unbox st)))
  (if (and m (eqv? (car args) (menu-did m))) (do-close s st) s))

(define (completion-install s)
  (let* ([s1 (session-service-put s 'complete (box #f))]
         [s2 (session-add-handler s1 (completion-handler))]
         [s3 (session-add-hook s2 (hook 'after-insert completion-refine-hook))]
         [s4 (session-add-hook s3 (hook 'focus-changed completion-cancel-hook))])
    (session-add-hook s4 (hook 'document-closed completion-doc-closed-hook))))

(define completion-spec
  (plugin-spec 'completion completion-install '()))
