#lang racket

;;; edit/plugin/builtin/completion.rkt —— 词补全（dabbrev 式）插件
;;;
;;; 菜单是**叠加层（deco）视图**（不抢焦点）；打开时压一个输入层（模态键表）：
;;;   · 上下/Enter/Tab/Esc 由层接管；
;;;   · 普通字符层里没有 → fallthrough 到文档键表 → cmd-insert → 本 handler 接手：
;;;     先插入再按新前缀刷新候选。
;;; 接受：把 [前缀起点, 光标) 换成候选。
;;;
;;; 候选 = 当前文档里出现过、以光标前缀开头、且不等于前缀的词（去重、排序）。
;;; 词法走 core/lex.rkt（与高亮同一套），前缀走 lex 的 prefix-at。

(require racket/list
         racket/string
         "../registry.rkt"
         "../../feature/api.rkt"
         "../../core/lex.rkt")

(provide completion-install completion-spec)

;;; ---------- 菜单状态 ----------

(struct menu (vid mvid start cands idx) #:transparent)
;; vid   : 编辑器 view（发起补全者，接受时改它）
;; mvid  : 菜单视图
;; start : (cons line col)  前缀起点
;; cands : (listof string)
;; idx   : 选中下标

(define max-rows 10)
(define menu-deep 2000)                            ; 远高于布局树

;;; ---------- 候选（纯） ----------

(define (candidates text prefix)
  (cond
    [(zero? (string-length prefix)) '()]
    [else
     (define seen (make-hash))
     (define out
       (for/fold ([acc '()]) ([tok (in-list (scan-words text))])
         (define w (cadddr tok))
         (if (and (string-prefix? w prefix) (not (string=? w prefix)) (not (hash-ref seen w #f)))
             (begin (hash-set! seen w #t) (cons w acc))
             acc)))
     (sort out string<?)]))

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
        (define cands (candidates text prefix))
        (cond
          [(null? cands) s]
          [else
           (define start (cons line (- col (string-length prefix))))
           (define-values (x y w h) (menu-rect s vid cands))
           (define-values (s1 _mdid mvid)
             (session-add-document s (menu-doc cands 0) w h #:name "*complete*"))
           (set-box! state (menu vid mvid start cands 0))
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
  (define cands (candidates text prefix))
  (cond
    [(null? cands) (do-close s state)]
    [else
     (define idx (min (menu-idx m) (sub1 (length cands))))
     (define start (cons line (- col (string-length prefix))))
     (set-box! state (menu vid (menu-mvid m) start cands idx))
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

(define (completion-handler box)
  (lambda (s cmd)
    (cond
      [(cmd-complete? cmd) (and (not (unbox box)) (do-open s box))]
      [(cmd-complete-move? cmd) (and (unbox box) (do-move s box (cmd-complete-move-dir cmd)))]
      [(cmd-complete-accept? cmd) (and (unbox box) (do-accept s box))]
      [(cmd-complete-cancel? cmd) (and (unbox box) (do-close s box))]
      [else #f])))

(define (completion-install s)
  (define state (box #f))
  (session-add-hook
   (session-add-hook (session-add-handler s (completion-handler state))
                     ;; 改文本后刷新候选（层里没有普通字符 → fallthrough 到文档键表 → 编辑原语 → 这里）
                     (hook 'after-edit (lambda (s _args) (if (unbox state) (do-refine s state) s))))
   ;; 焦点移开 → 取消菜单
   (hook 'focus-changed (lambda (s _args) (if (unbox state) (do-close s state) s)))))

(define completion-spec
  (plugin-spec 'completion completion-install '()))
