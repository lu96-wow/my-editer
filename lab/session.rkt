#lang racket

;;; session.rkt —— 会话：app 的**单一状态值**（不可变）
;;;
;;; 把原来散在 tui.rkt 的六个盒子（host / ws / status-id / tree-id / editor-id /
;;; prompt-action）收进一个 struct。所有状态迁移都靠「换一个新 session」，不再就地改。
;;;
;;; 组成：
;;;   host       core editor + 焦点 + 布局 + 组件注册（host.rkt）
;;;   ws         路径 ↔ 文档 映射（workspace.rkt）
;;;   modes      did → keymap（modes.rkt）
;;;   stack      瞬时模式栈（提示 / 确认 / 将来搜索）：栈顶在前
;;;   queue      待处理意图队列（命令可追加后续意图，如 tree → file/open）
;;;   pending    待确认意图（提示输入的名字 / 是否确认，见 command.rkt）
;;;   tree-id / status-id / editor-id   三个 app 级 pane id
;;;   global     全局 keymap（C-q / C-o 这类，永远垫在栈底）
;;;   quit?      退出标志
;;;
;;; 本模块**只有状态与存取器**，不含行为（行为在 command.rkt）。

(provide (struct-out session)
         (struct-out pending)
         session-open
         session-focus-id session-focus-vid session-focus-did session-set-focus
         session-set-host session-set-editor session-set-ws
         session-set-focus-vid
         session-pane-state session-set-pane-state session-pane-vid
         session-set-tree-id session-set-status-id session-set-editor-id session-set-ids
         session-set-mode session-remove-mode
         session-push-mode session-pop-mode session-mode-active?
         session-enqueue session-pop-intent session-queue-empty?
         session-set-pending session-set-quit
         session-resize
         session-keymaps session-layout)

(require "../core/editor.rkt"
         "host.rkt" "workspace.rkt" "modes.rkt" "keymap.rkt" "intent.rkt" "layout.rkt")

;; 待确认项：提示态确认时怎么解释缓冲。
(struct pending (kind on-yes on-no) #:transparent)
;; kind   : 'name（把缓冲当名字并入 on-yes 的 payload）| 'yesno（y → on-yes，n → on-no）
;; on-yes : intent
;; on-no  : (or/c #f intent)   'yesno 且输入 n 时入队；#f = 取消/忽略

(struct session
  (host ws modes stack queue tree-id status-id editor-id global pending quit?)
  #:transparent)
;; host      : host
;; ws        : ws
;; modes     : modes
;; stack     : (listof keymap)     瞬时模式栈，栈顶在前
;; queue     : (listof intent)     待处理意图（FIFO）
;; tree-id / status-id / editor-id : (or/c #f pane-id)
;; global    : keymap              全局键位（垫底）
;; pending   : (or/c #f pending?)    待确认项
;; quit?     : bool

(define (session-open host ws global)
  (session host ws (modes-empty) '() '() #f #f #f global #f #f))

;;; ---------- 焦点 ----------

(define (session-focus-id s) (host-focus-id (session-host s)))
(define (session-focus-vid s) (host-focused-vid (session-host s)))

(define (session-focus-did s)
  (define vid (session-focus-vid s))
  (and vid (editor-view-document-id (host-editor (session-host s)) vid)))

(define (session-set-focus s id)
  (struct-copy session s [host (host-set-focus (session-host s) id)]))

;;; ---------- host / editor ----------

(define (session-set-host s h) (struct-copy session s [host h]))

;; 焦点按 vid（鼠标点击 / 命中用）。
(define (session-set-focus-vid s vid)
  (struct-copy session s [host (host-set-focus-vid (session-host s) vid)]))

;; 组件 pane 状态存取（命令层转调 tree/status 的纯函数）。
(define (session-pane-state s id) (host-pane-state (session-host s) id))
(define (session-set-pane-state s id st)
  (struct-copy session s [host (host-set-pane-state (session-host s) id st)]))
(define (session-pane-vid s id) (host-pane-vid (session-host s) id))

(define (session-set-ws s w) (struct-copy session s [ws w]))

(define (session-set-editor s ed)
  (struct-copy session s [host (struct-copy host (session-host s) [editor ed])]))

;;; ---------- pane id ----------

(define (session-set-tree-id s id) (struct-copy session s [tree-id id]))
(define (session-set-status-id s id) (struct-copy session s [status-id id]))
(define (session-set-editor-id s id) (struct-copy session s [editor-id id]))
(define (session-set-ids s tree-id status-id editor-id)
  (struct-copy session s [tree-id tree-id] [status-id status-id] [editor-id editor-id]))

;;; ---------- 模式表（did → keymap） ----------

(define (session-set-mode s did km) (struct-copy session s [modes (modes-set (session-modes s) did km)]))
(define (session-remove-mode s did) (struct-copy session s [modes (modes-remove (session-modes s) did)]))

;;; ---------- 瞬时模式栈 ----------

(define (session-push-mode s km) (struct-copy session s [stack (cons km (session-stack s))]))
(define (session-pop-mode s)
  (struct-copy session s [stack (if (null? (session-stack s)) '() (cdr (session-stack s)))]))
(define (session-mode-active? s) (pair? (session-stack s)))

;;; ---------- 意图队列 ----------

(define (session-enqueue s . intents)
  (struct-copy session s [queue (append (session-queue s) intents)]))

(define (session-pop-intent s)
  (define q (session-queue s))
  (if (null? q)
      (values s #f)
      (values (struct-copy session s [queue (cdr q)]) (car q))))

(define (session-queue-empty? s) (null? (session-queue s)))

;;; ---------- 待确认意图 / 退出 ----------

(define (session-set-pending s p) (struct-copy session s [pending p]))
(define (session-set-quit s b) (struct-copy session s [quit? (and b #t)]))

;;; ---------- 尺寸 ----------

(define (session-resize s rows cols)
  (struct-copy session s [host (host-resize (session-host s) rows cols)]))

;;; ---------- 键位栈解析 ----------

;; 模式栈（栈顶在前） ++ [焦点文档 keymap] ++ [全局 keymap]。
(define (session-keymaps s)
  (define did (session-focus-did s))
  (define doc-km (and did (modes-of (session-modes s) did)))
  (filter values (append (session-stack s) (list doc-km) (list (session-global s)))))

;;; ---------- 布局 ----------

;; 左树(30) | 中编辑格 | 底状态栏(1 行)。
(define (session-layout s)
  (define t (session-tree-id s))
  (define e (session-editor-id s))
  (define st (session-status-id s))
  (and t e st (vsplit-bottom 1 (hsplit-left 30 t e 1) st)))

;;; ---------- 测试 ----------

(module+ test
  (require rackunit)

  (define ed0 (editor-open "" 40 10 #:line-numbers? #t))
  (define h0 (host-open ed0 10 40))
  (define-values (h1 eid) (host-adopt-view h0 0))
  (define g (km 'global '()))

  (define s0 (session-set-focus (session-open h1 (ws-empty) g) eid))
  (check-equal? (session-focus-id s0) eid)
  (check-equal? (session-focus-vid s0) 0)
  (check-equal? (session-focus-did s0) 0)                 ; editor-open 的文档 did = 0

  ;; keymap 栈：无模式时 = [文档 keymap?, 全局]。文档没登记 mode → 只剩全局
  (check-equal? (session-keymaps s0) (list g))

  ;; 登记 mode 后，文档 keymap 出现在全局之前
  (define dk (km 'doc '()))
  (define s1 (session-set-mode s0 0 dk))
  (check-equal? (session-keymaps s1) (list dk g))

  ;; 压一个瞬时模式 → 栈顶在前
  (define mk (km 'modal '()))
  (check-equal? (session-keymaps (session-push-mode s1 mk)) (list mk dk g))
  (check-equal? (session-keymaps (session-pop-mode (session-push-mode s1 mk))) (list dk g))

  ;; 队列 FIFO
  (define s2 (session-enqueue s0 (make-intent 'a) (make-intent 'b)))
  (define-values (s3 i1) (session-pop-intent s2))
  (define-values (s4 i2) (session-pop-intent s3))
  (define-values (s5 i3) (session-pop-intent s4))
  (check-equal? (intent-tag i1) 'a)
  (check-equal? (intent-tag i2) 'b)
  (check-false i3)
  (check-true (session-queue-empty? s5))

  (displayln "lab/session.rkt: all tests passed"))
