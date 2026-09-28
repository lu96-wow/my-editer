#lang racket

;;; ============================================================================
;;; lab/tui.rkt —— editor 的 app + 终端后端（**不属于 core**）
;;; ============================================================================
;;;
;;;   racket lab/tui.rkt
;;;
;;; 布局：左「文件树」| 中「单编辑格」| 底「状态栏」。
;;;   通用运行时   host.rkt（editor + 焦点 + 布局 + 帧 + 增量）
;;;   布局代数     layout.rkt
;;;   组件         status.rkt（状态栏）、tree.rkt（文件树）
;;;   文档管理     workspace.rkt（path ↔ document）
;;;
;;; 打开文件 = **单格替换**：ws-open 拿文档 → 关旧视图 + 加新视图 → 换掉编辑格 pane。
;;; 树只发 intent (list 'open path)，app 接 intent → ws-open → 显示。
;;;
;;; 键位：
;;;   可打印字符 / 粘贴     打字（焦点在编辑格时）
;;;   Enter / Tab           换行 / 制表
;;;   Backspace / Delete    退格 / 前向删除
;;;   ← → ↑ ↓ / Home / End  光标移动
;;;   PgUp / PgDn  Shift+方向 / Ctrl+K/L/R/N / Ctrl+Z/Y / Ctrl+C/V / Ctrl+D/M
;;;                         （同此前：编辑、扩选、高亮、只读、撤销、剪贴板、多选区）
;;;   Ctrl+O                切焦点：编辑格 ↔ 文件树
;;;   树有焦点时：方向键 = 普通光标移动（树就是个文档）；Enter 打开文件 / 展开收起目录
;;;                n 新建文件   m 新建文件夹   d 删除（目录需输入 y 确认；根目录禁删）
;;;   鼠标左键              点树：选中/展开/打开；点编辑格：定位；滚轮滚动
;;;   Ctrl+Q                退出

(require (except-in tui cursor-col)
         "../core/editor.rkt"
         (prefix-in c: "../core/editor.rkt")
         "../core/text/base/track.rkt"
         "../core/text/base/point.rkt"
         "../core/text/base/selection.rkt"
         "../core/view/base/screen.rkt"
         "../core/view/patch.rkt"
         "layout.rkt"
         "host.rkt"
         "fs.rkt"
         "status.rkt"
         "tree.rkt"
         "workspace.rkt")

;;; ---------- 宿主 / app 状态 ----------

(define host-box (box #f))
(define screen-box (box #f))              ; 最近一帧（测试 / 调试）
(define quit? (box #f))
(define ws-box (box (ws-empty)))          ; 文档管理
(define status-id-box (box #f))
(define tree-id-box (box #f))
(define editor-id-box (box #f))           ; 当前编辑格 pane id（打开文件会变）

(define (cur) (unbox host-box))
(define (fv) (host-focused-vid (cur)))    ; 焦点视图 id
(define (ced) (host-editor (cur)))

;;; ---------- 焦点糖 ----------

(define (editor-string ed) (editor-view-string ed (fv)))
(define (editor-selections ed) (editor-view-selections ed (fv)))
(define (editor-primary ed) (editor-view-primary ed (fv)))
(define (editor-selection-count ed) (editor-view-selection-count ed (fv)))
(define (editor-point-line ed) (editor-view-point-line ed (fv)))
(define (editor-point-col ed) (editor-view-point-col ed (fv)))
(define (editor-depth ed) (editor-view-depth ed (fv)))

(define (editor-insert ed text [tag #f]) (let-values ([(e _) (editor-view-insert ed (fv) text tag)]) e))
(define (editor-backspace ed [tag #f]) (let-values ([(e _) (editor-view-backspace ed (fv) tag)]) e))
(define (editor-delete ed [tag #f]) (let-values ([(e _) (editor-view-delete ed (fv) tag)]) e))
(define (editor-paste ed [tag #f]) (let-values ([(e _) (editor-view-paste ed (fv) tag)]) e))
(define (editor-copy ed) (editor-view-copy ed (fv)))
(define (editor-undo ed) (editor-view-undo ed (fv)))
(define (editor-redo ed) (editor-view-redo ed (fv)))
(define (editor-left ed [x #f]) (editor-view-left ed (fv) x))
(define (editor-right ed [x #f]) (editor-view-right ed (fv) x))
(define (editor-up ed [x #f]) (editor-view-up ed (fv) x))
(define (editor-down ed [x #f]) (editor-view-down ed (fv) x))
(define (editor-home ed [x #f]) (editor-view-home ed (fv) x))
(define (editor-end ed [x #f]) (editor-view-end ed (fv) x))
(define (editor-scroll ed d) (editor-view-scroll ed (fv) d))
(define (editor-goto ed p) (editor-view-set-point ed (fv) p))
(define (editor-set-selections ed s) (editor-view-set-selections ed (fv) s))
(define (editor-set-mode ed m) (editor-view-set-mode ed (fv) m))
(define (editor-toggle-line-numbers ed) (editor-view-toggle-line-numbers ed (fv)))
(define (editor-highlight ed face) (editor-view-highlight ed (fv) face))
(define (editor-readonly ed flag) (editor-view-readonly ed (fv) flag))

;;; ---------- 主题：face / overlay → 真彩色 ----------

(define (rgb-fg-bytes rgb) (if rgb (apply format-rgb-fg-base rgb) #""))
(define (rgb-bg-bytes rgb) (if rgb (apply format-rgb-bg-base rgb) #""))

(define (face-colors face)
  (cond [(not face)                (values #f #f)]
        [(eq? face 'line-number)   (values '(90 96 110) #f)]
        [(eq? face 'separator)     (values '(80 85 95) #f)]
        [(eq? face 'comment)       (values '(106 153 85) #f)]
        [(eq? face 'str)           (values '(206 145 120) #f)]
        [(eq? face 'num)           (values '(209 154 102) #f)]
        [(eq? face 'type)          (values '(229 192 123) #f)]
        [(eq? face 'fn)            (values '(97 175 239) #f)]
        [(eq? face 'kw)            (values '(198 120 221) #f)]
        [(eq? face 'status)        (values '(225 225 225) '(40 44 52))]
        [(eq? face 'tree-dir)      (values '(120 180 240) #f)]
        [(eq? face 'tree-file)     (values '(200 200 200) #f)]
        [(eq? face 'tree-open)     (values '(150 210 150) #f)]
        [else                      (values '(205 205 205) #f)]))

(define (overlay-colors ov)
  (case ov
    [(selection) (values #f '(58 74 128))]
    [else        (values #f #f)]))

(define (style-bytes attr)
  (define ov (and (pair? attr) (car attr)))
  (define face (if (pair? attr) (cdr attr) attr))
  (cond
    [(eq? ov 'cursor) format-reverse]
    [else
     (define-values (fg bg) (face-colors face))
     (define-values (ofg obg) (overlay-colors ov))
     (bytes-append (rgb-fg-bytes (or ofg fg)) (rgb-bg-bytes (or obg bg)))]))

;;; ---------- 帧 → 终端字节 ----------

(define (render-frame!)
  (define old (host-last-screen (cur)))
  (define-values (h1 screen render selection) (host-frame (cur)))
  (set-box! host-box h1)
  (set-box! screen-box screen)
  (values old screen render selection))

(define (draw!)
  (define-values (old new render selection) (render-frame!))
  (define parts '())
  (define (add! b) (set! parts (cons b parts)))
  (add! format-cursor-hide)
  (when (or (not old)
            (not (= (screen-width old) (screen-width new)))
            (not (= (screen-height old) (screen-height new))))
    (add! format-screen-clear))
  (for ([p (in-list (append render selection))])
    (add! (bytes-append (format-cursor-move (add1 (piece-row p)) (add1 (piece-col p)))
                        (style-bytes (piece-attr p))
                        (format-content (piece-text p))
                        format-reset)))
  (put-bytes (apply bytes-append (reverse parts)))
  (flush!))

(define (composed-screen)
  (define-values (_old screen _render _selection) (render-frame!))
  screen)

;;; ---------- 命令 ----------

(define (command-ed f ed)
  (call-with-values (lambda () (f ed)) (lambda (e . _) e)))

(define (set-msg h msg)
  (define sid (unbox status-id-box))
  (if sid (host-set-pane-state h sid (status-set-msg (host-pane-state h sid) msg)) h))

(define (edit! f)
  (define h (cur))
  (define ed* (command-ed f (host-editor h)))
  (set-box! host-box
            (set-msg (struct-copy host h [editor ed*])
                     (if (eq? ed* (host-editor h)) "只读：已拒绝" "")))
  (draw!))

(define (do! f)
  (define h (cur))
  (set-box! host-box
            (set-msg (struct-copy host h [editor (command-ed f (host-editor h))]) ""))
  (draw!))

;;; ---------- 焦点：树 ↔ 编辑格 ----------

(define (tree-focused?)
  (equal? (host-focus-id (cur)) (unbox tree-id-box)))

(define (toggle-focus!)
  (define h (cur))
  (define tid (unbox tree-id-box))
  (define eid (unbox editor-id-box))
  (set-box! host-box (host-set-focus h (if (equal? (host-focus-id h) tid) eid tid)))
  (draw!))

;;; ---------- 文件树动作（选中 = 光标所在行） ----------

(define (tree-vid) (host-pane-vid (cur) (unbox tree-id-box)))
(define (tree-line) (editor-view-point-line (host-editor (cur)) (tree-vid)))
(define (cur-entry) (tree-line-entry (host-pane-state (cur) (unbox tree-id-box)) (tree-line)))

;; 把光标放到树的第 line 行（core 会 ensure → 自动滚动）
(define (tree-set-line! h line)
  (define ed (host-editor h))
  (define vid (host-pane-vid h (unbox tree-id-box)))
  (struct-copy host h [editor (editor-view-set-point ed vid (point line 0))]))

(define (tree-line-of st path)
  (for/first ([v (in-list (tree-visible st))] [i (in-naturals)]
              #:when (equal? (entry-path (cdr v)) path)) i))

(define (handle-intent! intent)
  (case (car intent)
    [(open) (open-path! (cadr intent))]
    [else (void)]))

(define (tree-activate!)
  (define e (cur-entry))
  (define h (cur))
  (define tid (unbox tree-id-box))
  (define-values (st* intent) (tree-activate (host-pane-state h tid) e))
  (set-box! host-box (host-set-pane-state h tid st*))
  (when intent (handle-intent! intent))
  (draw!))

;;; ---------- 打开文件 = 单格替换 ----------

(define (build-layout tree-id editor-id status-id)
  (vsplit-bottom 1 (hsplit-left 30 tree-id editor-id 1) status-id))

;; 给 did 建视图并注册为编辑格 pane（不动旧的）→ 新 host
(define (install-editor! h did)
  (define ch (max 1 (sub1 (host-rows h))))
  (define-values (ed2 new-vid) (c:editor-add-view (host-editor h) did 40 ch 'free #f #:line-numbers? #t))
  (define-values (h1 new-eid) (host-adopt-view (struct-copy host h [editor ed2]) new-vid))
  (define h2 (host-set-layout h1 (build-layout (unbox tree-id-box) new-eid (unbox status-id-box))))
  (set-box! editor-id-box new-eid)
  (host-set-focus h2 new-eid))

;; 关旧视图再装新 did（打开文件用）
(define (swap-editor! h did)
  (define eid (unbox editor-id-box))
  (define ed (c:editor-close-view (host-editor h) (host-pane-vid h eid)))
  (install-editor! (struct-copy host h [editor ed]) did))

;; 把 workspace 的「已打开」集合同步给树
(define (sync-tree-open! h)
  (define tid (unbox tree-id-box))
  (host-set-pane-state h tid
    (tree-set-open-paths (host-pane-state h tid) (ws-open-paths (unbox ws-box)))))

(define (open-path! path)
  (define h (cur))
  (define eid (unbox editor-id-box))
  (define old-vid (host-pane-vid h eid))
  (define ws (unbox ws-box))
  (define-values (ws* ed1 did) (ws-open ws (host-editor h) path))
  (set-box! ws-box ws*)
  (cond
    ;; 已经是这个文档 → 只把焦点还回编辑格
    [(= did (editor-view-document-id ed1 old-vid))
     (set-box! host-box (host-set-focus h eid))]
    [else
     (define h1 (swap-editor! (struct-copy host h [editor ed1]) did))
     (set-box! host-box (sync-tree-open! h1))]))

;; 删除的文件若正被打开：关掉它的文档；若编辑格正显示它，换成空 scratch。
;; 注意 ws-close → editor-close-document 会**连带删掉该文档的所有视图**，
;; 所以若编辑格正显示它，必须先把编辑格 pane 摘掉，免得 host 指向已消失的 view。
(define (close-deleted! path)
  (define ws (unbox ws-box))
  (define did (ws-did ws path))
  (when did
    (define h (cur))
    (define eid (unbox editor-id-box))
    (define cur-did (editor-view-document-id (host-editor h) (host-pane-vid h eid)))
    (define on-deleted? (= did cur-did))
    (define h0 (if on-deleted? (host-remove-pane h eid) h))
    (define-values (ws* ed1) (ws-close ws (host-editor h0) did))
    (set-box! ws-box ws*)
    (define h1
      (if on-deleted?
          (let-values ([(ed2 new-did) (c:editor-add-document ed1 "" "*scratch*")])
            (install-editor! (struct-copy host h0 [editor ed2]) new-did))
          (struct-copy host h0 [editor ed1])))
    (set-box! host-box (sync-tree-open! h1))))

;;; ---------- 文件树命令：建 / 删（命名走状态栏提示） ----------

(define (tree-create! kind name)
  (define e (cur-entry))
  (define h (cur))
  (define tid (unbox tree-id-box))
  (define-values (st* path) (tree-create (host-pane-state h tid) e kind name))
  (define h1 (host-set-pane-state h tid st*))
  (define line (tree-line-of st* path))
  (set-box! host-box (if line (tree-set-line! h1 line) h1))
  (draw!))

(define (tree-do-delete! e)
  (define line (tree-line))
  (define h (cur))
  (define tid (unbox tree-id-box))
  (define-values (st* path) (tree-delete (host-pane-state h tid) e))
  (define h1 (host-set-pane-state h tid st*))
  (define n (length (tree-visible st*)))
  (set-box! host-box (if (> n 0) (tree-set-line! h1 (min line (sub1 n))) h1))
  (when path (close-deleted! path))
  (draw!))

;; 删选中：根目录禁删；目录要确认；文件即时删。
(define (tree-delete!)
  (define e (cur-entry))
  (cond
    [(not e) (void)]
    [(equal? (entry-path e)
             (entry-path (tree-root (host-pane-state (cur) (unbox tree-id-box)))))
     (set-box! host-box (set-msg (cur) "根目录不能删除"))
     (draw!)]
    [(entry-dir? e)
     (prompt-start! (format "删除目录 ~a 及其全部内容？输入 y 回车确认 " (entry-name e)) ""
                    (lambda (buf) (when (string-ci=? buf "y") (tree-do-delete! e))))]
    [else (tree-do-delete! e)]))

(define (tree-command! s)
  (cond
    [(string=? s "n") (prompt-start! "新建文件: " "untitled" (lambda (name) (tree-create! 'file name)))]
    [(string=? s "m") (prompt-start! "新建文件夹: " "new-folder" (lambda (name) (tree-create! 'dir name)))]
    [(string=? s "d") (tree-delete!)]
    [else (void)]))

;;; ---------- 状态栏提示（命名输入） ----------

(define prompt-action-box (box #f))

(define (status-st) (host-pane-state (cur) (unbox status-id-box)))
(define (prompting?) (status-prompting? (status-st)))

(define (prompt-start! label default action)
  (set-box! prompt-action-box action)
  (define h (cur))
  (set-box! host-box (host-set-pane-state h (unbox status-id-box)
                     (status-start-prompt (host-pane-state h (unbox status-id-box)) label default)))
  (draw!))

(define (prompt-cancel!)
  (define h (cur))
  (set-box! host-box (host-set-pane-state h (unbox status-id-box)
                     (status-clear-prompt (host-pane-state h (unbox status-id-box)))))
  (set-box! prompt-action-box #f)
  (draw!))

(define (prompt-confirm!)
  (define buf (status-input-buffer (status-st)))
  (define act (unbox prompt-action-box))
  (define h (cur))
  (set-box! host-box (host-set-pane-state h (unbox status-id-box)
                     (status-clear-prompt (host-pane-state h (unbox status-id-box)))))
  (set-box! prompt-action-box #f)
  (when (and act (not (string=? buf ""))) (act buf))
  (draw!))

(define (prompt-insert! s)
  (define h (cur))
  (define st (host-pane-state h (unbox status-id-box)))
  (set-box! host-box (host-set-pane-state h (unbox status-id-box)
                     (status-set-buffer st (string-append (status-input-buffer st) s))))
  (draw!))

(define (prompt-backspace!)
  (define st (status-st))
  (define b (status-input-buffer st))
  (when (> (string-length b) 0)
    (define h (cur))
    (set-box! host-box (host-set-pane-state h (unbox status-id-box)
                       (status-set-buffer st (substring b 0 (sub1 (string-length b))))))
    (draw!)))

;;; ---------- 鼠标 ----------

(define (mouse-1based->0based x y) (values (max 0 (sub1 x)) (max 0 (sub1 y))))

(define (mouse-goto h x y)
  (define-values (vid ly lx) (host-view-at h y x))
  (cond
    [(not vid) h]
    [else
     (define h* (host-set-focus-vid h vid))
     (define ed (host-editor h*))
     (define-values (line col) (editor-view-screen-pos->point ed vid ly lx))
     (cond
       [(not line) (set-msg h* "")]
       [else (set-msg (struct-copy host h* [editor (editor-view-set-point ed vid (point line col))]) "")])]))

(define (mouse-add-cursor h x y)
  (define-values (vid ly lx) (host-view-at h y x))
  (cond
    [(not vid) h]
    [else
     (define h* (host-set-focus-vid h vid))
     (define ed (host-editor h*))
     (define-values (line col) (editor-view-screen-pos->point ed vid ly lx))
     (cond
       [(not line) h*]
       [else
        (define ss* (selections-add-primary (editor-view-selections ed vid) (caret (point line col))))
        (set-msg (struct-copy host h* [editor (editor-view-set-selections ed vid ss*)]) "加光标")])]))

;;; ---------- 视口 / 动作 ----------

(define (page-size)
  (max 1 (sub1 (editor-view-height (ced) (fv)))))

(define (toggle-wrap ed)
  (define m (if (eq? (editor-view-mode ed (fv)) 'clip) 'wrap 'clip))
  (editor-set-mode ed m))

;;; ---------- 多选区 ----------

(define (collapse-to-primary ed)
  (editor-set-selections ed (selections-one (selections-primary (editor-selections ed)))))

(define (doc-lines ed) (string-split (editor-string ed) "\n" #:trim? #f))
(define (word-char? c) (or (char-alphabetic? c) (char-numeric? c) (char=? c #\_)))

(define (word-range line col)
  (define n (string-length line))
  (define (at i) (and (< i n) (word-char? (string-ref line i))))
  (define c (cond [(and (< col n) (at col)) col]
                  [(and (> col 0) (at (sub1 col))) (sub1 col)]
                  [else #f]))
  (cond
    [(not c) (values (min col n) (min col n))]
    [else
     (values (let loop ([i c]) (if (and (> i 0) (at (sub1 i))) (loop (sub1 i)) i))
             (let loop ([i c]) (if (at i) (loop (add1 i)) i)))]))

(define (line-matches line needle)
  (for/list ([m (in-list (regexp-match-positions* (regexp (regexp-quote needle)) line))])
    (car m)))

(define (selection-text ed s)
  (define-values (a b) (selection-range s))
  (and (= (point-line a) (point-line b))
       (substring (list-ref (doc-lines ed) (point-line a)) (point-col a) (point-col b))))

(define (selection-ranges ss)
  (for/list ([s (in-list (selections-items ss))])
    (call-with-values (lambda () (selection-range s)) cons)))

(define (next-match ed needle after ss)
  (define n (string-length needle))
  (define ranges (selection-ranges ss))
  (define (overlaps? a b)
    (for/or ([r (in-list ranges)]) (and (point<? (car r) b) (point<? a (cdr r)))))
  (define matches
    (append*
     (for/list ([line (in-list (doc-lines ed))] [li (in-naturals)])
       (for/list ([start (in-list (line-matches line needle))])
         (cons (point li start) (point li (+ start n)))))))
  (define ordered (append (filter (lambda (m) (point<? after (car m))) matches)
                          (filter (lambda (m) (point<=? (car m) after)) matches)))
  (for/first ([m (in-list ordered)] #:unless (overlaps? (car m) (cdr m))) m))

(define (selections-add-primary ss sel)
  (selections-dedupe
   (selections-set-primary (selections-add ss (list sel)) (selections-count ss))))

(define (multi-add-next ed)
  (define ss (editor-selections ed))
  (define prim (selections-primary ss))
  (define-values (a b) (selection-range prim))
  (cond
    [(point=? a b)
     (define line (point-line a))
     (define-values (ws we) (word-range (list-ref (doc-lines ed) line) (point-col a)))
     (if (= ws we)
         ed
         (editor-set-selections ed (selections-one (selection (point line ws) (point line we)))))]
    [else
     (define needle (selection-text ed prim))
     (cond
       [(or (not needle) (string=? needle "")) ed]
       [else
        (define m (next-match ed needle b ss))
        (cond [(not m) ed]
              [else (editor-set-selections ed (selections-add-primary ss (selection (car m) (cdr m))))])])]))

(define (multi-add-all ed)
  (define ss (editor-selections ed))
  (define prim (selections-primary ss))
  (define-values (a b) (selection-range prim))
  (cond
    [(point=? a b)
     (define ed* (multi-add-next ed))
     (if (eq? ed* ed) ed (multi-add-all ed*))]
    [else
     (define needle (selection-text ed prim))
     (cond
       [(or (not needle) (string=? needle "")) ed]
       [else
        (define n (string-length needle))
        (define all
          (append*
           (for/list ([line (in-list (doc-lines ed))] [li (in-naturals)])
             (for/list ([start (in-list (line-matches line needle))])
               (selection (point li start) (point li (+ start n)))))))
        (cond
          [(null? all) ed]
          [else (editor-set-selections ed
                  (selections-normalize
                   (selections-set-primary-value (selections all 0) prim)))])])]))

(define (multi-add-line ed delta)
  (define ss (editor-selections ed))
  (define p (selection-point (selections-primary ss)))
  (define lines (doc-lines ed))
  (define l (+ (point-line p) delta))
  (cond
    [(or (< l 0) (>= l (length lines))) ed]
    [else
     (define col (min (point-col p) (string-length (list-ref lines l))))
     (editor-set-selections ed (selections-add-primary ss (caret (point l col))))]))

;;; ---------- 输入 ----------

(define (make-handler)
  (build-input
   #:text      (lambda (s)
                 (cond [(prompting?) (prompt-insert! s)]
                       [(tree-focused?) (if (= 1 (string-length s)) (tree-command! s) (void))]
                       [else (edit! (lambda (ed) (editor-insert ed s 'typing)))]))
   #:enter     (lambda ()
                 (cond [(prompting?) (prompt-confirm!)]
                       [(tree-focused?) (tree-activate!)]
                       [else (edit! (lambda (ed) (editor-insert ed "\n")))]))
   #:tab       (lambda () (unless (or (prompting?) (tree-focused?))
                            (edit! (lambda (ed) (editor-insert ed "    ")))))
   #:backspace (lambda ()
                 (cond [(prompting?) (prompt-backspace!)]
                       [(tree-focused?) (void)]
                       [else (edit! (lambda (ed) (editor-backspace ed 'backspace)))]))
   #:delete    (lambda () (unless (or (prompting?) (tree-focused?))
                            (edit! (lambda (ed) (editor-delete ed 'delete)))))
   #:left      (lambda () (unless (prompting?) (do! (lambda (ed) (editor-left ed)))))
   #:right     (lambda () (unless (prompting?) (do! (lambda (ed) (editor-right ed)))))
   #:up        (lambda () (unless (prompting?) (do! (lambda (ed) (editor-up ed)))))
   #:down      (lambda () (unless (prompting?) (do! (lambda (ed) (editor-down ed)))))
   #:home      (lambda () (unless (or (prompting?) (tree-focused?)) (do! (lambda (ed) (editor-home ed)))))
   #:end       (lambda () (unless (or (prompting?) (tree-focused?)) (do! (lambda (ed) (editor-end ed)))))
   #:pageup    (lambda () (unless (or (prompting?) (tree-focused?))
                            (do! (lambda (ed) (editor-scroll ed (- (page-size)))))))
   #:pagedown  (lambda () (unless (or (prompting?) (tree-focused?))
                            (do! (lambda (ed) (editor-scroll ed (page-size))))))
   #:escape    (lambda () (cond [(prompting?) (prompt-cancel!)]
                                [(tree-focused?) (void)]
                                [else (do! collapse-to-primary)]))
   #:mouse     (lambda (action button x y mods)
                 (when (not (prompting?))
                   (case action
                     [(press)
                      (when (eq? button 'left)
                        (define-values (mx my) (mouse-1based->0based x y))
                        (set-box! host-box (if (mods-alt? mods)
                                               (mouse-add-cursor (cur) mx my)
                                               (mouse-goto (cur) mx my)))
                        (draw!))]
                     [(scroll) (unless (tree-focused?)
                                 (do! (lambda (ed) (editor-scroll ed (if (eq? button 'up) -3 3)))))]
                     [else (void)])))
   #:resize    (lambda (rows cols)
                 (set-box! host-box (set-msg (host-resize (cur) rows cols) ""))
                 (draw!))
   #:key       (lambda (key mods)
                 (cond
                   [(and (char? key) (mods-ctrl? mods) (char=? (char-downcase key) #\q))
                    (set-box! quit? #t)]
                   [(prompting?) (void)]
                   [(and (char? key) (mods-ctrl? mods) (char=? (char-downcase key) #\o))
                    (toggle-focus!)]
                   [(and (char? key) (mods-ctrl? mods))
                    (case (char-downcase key)
                      [(#\z) (do! editor-undo)]
                      [(#\y) (do! editor-redo)]
                      [(#\c) (do! editor-copy)]
                      [(#\v) (do! editor-paste)]
                      [(#\t) (do! toggle-wrap)]
                      [(#\g) (do! editor-toggle-line-numbers)]
                      [(#\d) (do! multi-add-next)]
                      [(#\m) (do! multi-add-all)]
                      [(#\k) (do! (lambda (ed) (editor-highlight ed 'kw)))]
                      [(#\l) (do! (lambda (ed) (editor-highlight ed #f)))]
                      [(#\r) (do! (lambda (ed) (editor-readonly ed #t)))]
                      [(#\n) (do! (lambda (ed) (editor-readonly ed #f)))]
                      [else (void)])]
                   [(and (symbol? key) (mods-ctrl? mods) (mods-shift? mods))
                    (case key
                      [(down) (do! (lambda (ed) (multi-add-line ed +1)))]
                      [(up) (do! (lambda (ed) (multi-add-line ed -1)))]
                      [else (void)])]
                   [(and (symbol? key) (mods-alt? mods))
                    (case key
                      [(down) (do! (lambda (ed) (multi-add-line ed +1)))]
                      [(up) (do! (lambda (ed) (multi-add-line ed -1)))]
                      [else (void)])]
                   [(mods-shift? mods)
                    (case key
                      [(left) (do! (lambda (ed) (editor-left ed #t)))]
                      [(right) (do! (lambda (ed) (editor-right ed #t)))]
                      [(up) (do! (lambda (ed) (editor-up ed #t)))]
                      [(down) (do! (lambda (ed) (editor-down ed #t)))]
                      [else (void)])]
                   [else (void)]))))

;;; ---------- 组装 / 主循环 ----------

;; 树（左）| 编辑格（中）| 状态栏（底）
(define (setup! rows cols #:root [root (current-directory)] #:fs [fs (fs-real)])
  (define ch (max 1 (sub1 rows)))                              ; 内容区高（状态栏占 1 行）
  (define ed0 (c:editor-open "" 40 ch #:line-numbers? #t))   ; 初始：空的无标题文档
  (define h0 (host-open ed0 rows cols))
  (define-values (h1 eid) (host-adopt-view h0 0))              ; 编辑格（初始 scratch）
  (define-values (h2 tid) (host-add-document h1 "" 30 ch "*tree*"   ; 文件树组件
                                             #:history? #f
                                             #:sync tree-sync
                                             #:state (tree-open root fs)))
  (define-values (h3 sid) (host-add-document h2 "" cols 1 "*status*" ; 状态栏组件
                                             #:history? #f
                                             #:sync status-sync
                                             #:state (status "" #f)))
  (define h4 (host-set-layout h3 (build-layout tid eid sid)))
  (define h5 (host-set-focus h4 eid))
  (set-box! host-box h5)
  (set-box! ws-box (ws-empty))
  (set-box! status-id-box sid)
  (set-box! tree-id-box tid)
  (set-box! editor-id-box eid)
  (set-box! screen-box #f)
  (set-box! quit? #f))

(module+ main
  (with-tui
   (lambda ()
     (define-values (r c) (get-window-size))
     (setup! (max 2 (or r 24)) (max 1 (or c 80)))
     (draw!)
     (loop-input/stop (unbox quit?) (make-handler)))))

;;; ---------- 无 TTY 冒烟测试 ----------

(module+ test
  (require rackunit racket/file "../core/text/document.rkt")

  (define nowhere (open-output-nowhere))
  (define dir (make-temporary-file "tuidir-~a" 'directory))
  (define sub (build-path dir "sub"))
  (make-directory sub)
  (define tmp (build-path dir "a.txt"))
  (define ms (build-path dir "b.txt"))
  (display-to-file "FILE CONTENT\nsecond line\n" tmp #:exists 'replace)
  (display-to-file "foo bar\nfoo baz\nfoo\n" ms #:exists 'replace)

  (setup! 20 80 #:root dir #:fs (fs-real))
  (define h (make-handler))
  (define (ed) (host-editor (cur)))
  (define (evid) (host-pane-vid (cur) (unbox editor-id-box)))
  (define (tid) (unbox tree-id-box))
  (define (ps p) (path->string p))

  ;; 布局：树 | 编辑格 | 状态栏
  (define s0 (composed-screen))
  (check-equal? (screen-width s0) 80)
  (check-equal? (screen-height s0) 20)
  ;; 根行显示绝对路径
  (check-true (for/or ([rn (in-list (screen-row s0 0))])
                (regexp-match? #rx"tuidir" (run-text rn))))
  (check-true (for/or ([rn (in-list (screen-row s0 0))]) (>= (run-col rn) 31)))
  (check-true (for/or ([rn (in-list (screen-row s0 19))]) (eq? (run-face rn) 'status)))

  (parameterize ([current-output-port nowhere])
    ;; 初始焦点在编辑格
    (h (key-event #\X (mods #f #f #f)))
    (check-equal? (substring (editor-view-string (ed) (evid)) 0 1) "X")

    ;; ---------- 树就是普通文档：core 光标导航 ----------
    (h (key-event #\o (mods #t #f #f)))
    (check-true (tree-focused?))
    (check-equal? (ps (entry-path (cur-entry))) (ps dir))          ; 初始光标在根行
    (h (key-event 'down (mods #f #f #f)))                          ; → sub
    (check-equal? (ps (entry-path (cur-entry))) (ps sub))
    (h (key-event 'down (mods #f #f #f)))                          ; → a.txt
    (check-equal? (ps (entry-path (cur-entry))) (ps tmp))
    ;; 回车打开（树 → intent → ws-open → 单格替换）
    (tree-activate!)
    (check-equal? (editor-view-string (ed) (evid)) "FILE CONTENT\nsecond line\n")
    (check-true (ws-open? (unbox ws-box) tmp))
    (check-false (tree-focused?))
    (check-true (hash-has-key? (tree-open-paths (host-pane-state (cur) (tid))) tmp))

    ;; 再次打开同一个文件 → 复用文档
    (define did-before (editor-view-document-id (ed) (evid)))
    (open-path! tmp)
    (check-equal? (editor-view-document-id (ed) (evid)) did-before)

    ;; ---------- 建 / 删 ----------
    (h (key-event #\o (mods #t #f #f)))                           ; 焦点回树（光标仍在 a.txt）
    (h (key-event 'up (mods #f #f #f)))                            ; → sub
    (check-equal? (ps (entry-path (cur-entry))) (ps sub))
    (h (key-event #\n (mods #f #f #f)))                           ; 命名提示
    (check-true (prompting?))
    (check-true (for/or ([rn (in-list (screen-row (composed-screen) 19))])
                  (regexp-match? #rx"新建文件" (run-text rn))))
    (h (key-event 'enter (mods #f #f #f)))                         ; 用默认名 untitled
    (check-false (prompting?))
    (define made (build-path sub "untitled"))
    (check-true (file-exists? made))
    (check-equal? (ps (entry-path (cur-entry))) (ps made))         ; 光标落到新项
    (h (key-event #\d (mods #f #f #f)))                           ; 删文件：即时
    (check-false (file-exists? made))

    ;; 删目录：需确认；Esc 取消，输入 y 才删
    (set-box! host-box (tree-set-line! (cur) (tree-line-of (host-pane-state (cur) (tid)) sub)))
    (h (key-event #\d (mods #f #f #f)))
    (check-true (prompting?))
    (check-true (directory-exists? sub))                            ; 还没删
    (h (key-event 'escape (mods #f #f #f)))                         ; 取消
    (check-false (prompting?))
    (check-true (directory-exists? sub))
    (h (key-event #\d (mods #f #f #f)))                            ; 再来，输入 y 回车
    (check-true (prompting?))
    (h (key-event #\y (mods #f #f #f)))
    (h (key-event 'enter (mods #f #f #f)))
    (check-false (prompting?))
    (check-false (directory-exists? sub))

    ;; 根目录：禁删
    (set-box! host-box (tree-set-line! (cur) 0))
    (h (key-event #\d (mods #f #f #f)))
    (check-true (directory-exists? dir))
    (check-false (prompting?))

    ;; 删除已打开的文件 → 关文档 + 编辑格换空 scratch
    (open-path! ms)
    (h (key-event #\o (mods #t #f #f)))
    (set-box! host-box (tree-set-line! (cur) (tree-line-of (host-pane-state (cur) (tid)) ms)))
    (check-equal? (ps (entry-path (cur-entry))) (ps ms))
    (h (key-event #\d (mods #f #f #f)))
    (check-false (file-exists? ms))
    (check-false (ws-open? (unbox ws-box) ms))
    (check-equal? (editor-view-string (ed) (evid)) "")

    ;; ---------- 编辑格多选区 ----------
    (open-path! tmp)
    (do! (lambda (e) (editor-goto e (point 0 0))))
    (h (key-event #\d (mods #t #f #f)))
    (h (key-event #\X (mods #f #f #f)))
    (check-equal? (substring (editor-view-string (ed) (evid)) 0 6) "X CONT")

    ;; resize
    (set-box! host-box (host-resize (cur) 14 50))
    (let ([s1 (composed-screen)])
      (check-equal? (screen-width s1) 50)
      (check-equal? (screen-height s1) 14)))

  (delete-directory/files dir)
  (displayln "lab/tui.rkt: all tests passed"))
