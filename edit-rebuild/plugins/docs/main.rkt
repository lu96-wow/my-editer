#lang racket

;;; edit-rebuild/plugins/docs/main.rkt —— 文档浮窗插件（独立于补全）
;;;
;;; 只负责「把某个标识符的文档显示在一个可滚动的浮动窗口里」，不认识补全：
;;;   · 订阅补全发布的 `complete-selection`（选中项变化 → 查它的文档）；
;;;   · 也可用命令 `cmd-docs-show`（M-d）对**光标处标识符**独立查询；
;;;   · 异步走 doc-job（自己的 place worker / 闸门），从不等补全 / 不阻塞；
;;;   · 浮窗是一个 **float 面（surface）**：由 session/surfaces.rkt 组合进会话，
;;;     落位用 geometry/popup.rkt（避开补全菜单、不遮挡光标行）；
;;;   · 窗口高度有上界，内容超出就滚动（不必一次显示完）。
;;;
;;; 与补全的事件契约（两边都不 require 对方）：
;;;   complete-selection  args = (vid name mods menu-rect) | (vid #f #f #f)
;;;       doc 订阅：新选中 → 查文档；#f → 关窗
;;;   docs-state          args = (open?)        doc 广播：文档窗开关（补全据此决定 Tab 是否切换）
;;;   docs-scroll         args = (delta)       doc 订阅：按 delta 行滚动
;;;   docs-focus          args = (active?)      doc 订阅：是否接键（决定正文亮/暗）

(require racket/list
         racket/match
         racket/path
         "../../core/extension/api.rkt"
         "../../core/extension/spec.rkt"
         "../../core/face/lex.rkt"
         "../../core/face/kind.rkt"
         "../../core/geometry/popup.rkt"
         "../../core/geometry/layout.rkt"
         "../lang/source.rkt"
         "../lang/docs.rkt"
         "../lang/wrap.rkt"
         "job.rkt")

(provide docs-install docs-spec)

;;; ---------- 状态 ----------

(struct d-svc (win seq menu-rect last-key pending focus) #:transparent)
;; win       : box (docwin | #f)     文档浮窗
;; seq       : box integer           请求序号（判定迟到结果）
;; menu-rect : box ((list x y w h) | #f)  补全菜单矩形（避让用）
;; last-key  : box any/c             上次已查询的键（name+mods），避免重复请求
;; pending   : box ((list vid name mods) | #f)  待处理选中项（本帧内只记，不做事）
;; focus     : box boolean           是否接键（Tab 切过来时高亮）

(struct docwin (vid mvid ddid text lines offset) #:transparent)
;; vid    : 源编辑器视图（锚点）
;; mvid   : 文档窗视图
;; ddid   : 文档窗自己的 document id
;; text   : string            原始正文（未折行）
;; lines  : (listof string)   折行后的全部显示行（滚动用）
;; offset : nat               当前顶部行

(define (docs-svc s) (session-service-ref s 'docs))
(define doc-max-rows 18)            ; 窗口高度上界（实际取 min(此, 半屏)）
(define doc-pref-width 60)
(define doc-deep 2001)

;; 视图还活着吗（关视图 / 换 buffer 后浮窗要失效）。
(define (live-view? s vid) (and vid (memv vid (session-view-id-list s)) #t))

;;; ---------- 窗口内容 / 几何 ----------

(define (doc-width s)
  (max 10 (min doc-pref-width (max 10 (- (session-width s) 2)))))

;; 窗口**外框**高度（含上下边框）：合适即可，不满屏也不撑满内容。
(define (doc-outer-height s)
  (max 6 (min doc-max-rows (quotient (session-height s) 2))))

;; 内容区行数 = 外框 - 2（上下边框）。
(define (doc-content-rows s)
  (max 1 (- (doc-outer-height s) 2)))

;; 当前可见的一段（按 offset / 窗口高度切片）。
(define (doc-visible s dw)
  (define lines (docwin-lines dw))
  (define n (length lines))
  (define rows (min n (doc-content-rows s)))
  (define off (max 0 (min (docwin-offset dw) (max 0 (- n rows)))))
  (take (drop lines off) rows))

(define (doc-doc lines face)
  (panel-doc (for/list ([l (in-list lines)]) (list (string-append " " l) face))))

(define (doc-face svc) (if (unbox (d-svc-focus svc)) 'docs 'docs-dim))

;; 重装文档文档（滚动 / 焦点变化后）。
(define (refresh-doc-window! s)
  (define svc (docs-svc s))
  (define dw (and svc (unbox (d-svc-win svc))))
  (cond
    [(not dw) s]
    [else
     (session-ed-assign! s (docwin-mvid dw) (doc-doc (doc-visible s dw) (doc-face svc)))]))

;; 文档窗布局：矩形（有补全菜单矩形时避让；否则独立落位）。→ (values x y w h)
(define (doc-layout s dw)
  (define-values (col row) (session-view-cursor-screen s (docwin-vid dw)))
  (define c (or col 0))
  (define r (or row 0))
  (define sw (session-width s))
  (define sh (session-height s))
  (define w (doc-width s))
  (define want-h (max 1 (+ 2 (length (doc-visible s dw)))))   ; 外框高 = 内容行 + 2 边框
  (define rect (and (docs-svc s) (unbox (d-svc-menu-rect (docs-svc s)))))
  (cond
    [rect
     (match-define (list ax ay aw ah) rect)
     (popup-rect-avoiding r c w want-h sw sh ax ay aw ah #:share? #t)]
    [else
     (popup-rect r c w want-h sw sh)]))

;; 浮面落位：源视图还在、光标在视口内才显示。→ (list x y w h) | #f
(define (doc-pos s dw)
  (define vid (docwin-vid dw))
  (and (live-view? s vid)
       (let-values ([(col _row) (session-view-cursor-screen s vid)])
         (and col
              (let-values ([(x y w h) (doc-layout s dw)])
                (and (positive? h) (area x y w h)))))))

;;; ---------- 开 / 关 ----------

;; 移除文档窗（面 / 状态；document 还在就关）。改 seq；广播 docs-state #f。
(define (remove-doc-window! s)
  (define svc (docs-svc s))
  (define dw (and svc (unbox (d-svc-win svc))))
  (cond
    [(not dw) s]
    [else
     (set-box! (d-svc-win svc) #f)
     (define mvid (docwin-mvid dw))
     (define ddid (docwin-ddid dw))
     (define s1 (session-remove-surface s 'docs))
     (define s2 (if (memv ddid (session-document-ids s1))
                    (session-close-document s1 ddid)
                    s1))
     (session-run-hooks s2 'docs-state (list #f))]))

(define (bump-seq! svc) (set-box! (d-svc-seq svc) (add1 (unbox (d-svc-seq svc)))))

;; 关文档窗（并使在途结果失效）。
(define (close-docs s)
  (define svc (docs-svc s))
  (cond
    [(not svc) s]
    [else (bump-seq! svc) (remove-doc-window! s)]))

;; 打开 / 更新文档窗（保证单实例）。开窗后广播 docs-state #t。
(define (open-window! s svc vid text)
  (define width (doc-width s))
  (define all (wrap-lines text (max 1 (- width 3))))     ; 内容宽 = 外宽 - 2 边框 - 1 前导空格
  (cond
    [(null? all) s]
    [else
     (define rows (min (length all) (doc-content-rows s)))
     (define s0 (remove-doc-window! s))
     (define-values (s1 ddid mvid)
       (session-add-document s0 (doc-doc (take all rows) (doc-face svc))
                             width (+ rows 2) #:name "*docs*"))
     (define dw (docwin vid mvid ddid text all 0))
     (set-box! (d-svc-win svc) dw)
     (define s2 (session-add-surface s1
                  (float-surface 'docs mvid #f
                                 (float (lambda (s) (doc-pos s dw)) doc-deep)
                                 #f #f #f #f
                                 #:border 'window-border)))
     (session-run-hooks s2 'docs-state (list #t))]))

;; worker 结果 (name sig body) → 显示文本。
(define (result->doc-text r)
  (and (list? r)
       (= 3 (length r))
       (let ([sig (cadr r)] [body (caddr r)])
         (string-append (or sig "")
                        (if body (string-append (if sig "\n\n" "") body) "")
                        "\n"))))

;; 提交一次查询并登记闸门；迟到结果按 seq 丢弃。返回新 session（不等结果）。
(define (request-docs! s svc vid name mods)
  (bump-seq! svc)
  (define seq (unbox (d-svc-seq svc)))
  (define s1 (remove-doc-window! s))
  (define id (doc-request! s1 (if (string? name) name (format "~a" name)) mods))
  (session-await s1 id seq
    (lambda (_s tok) (= tok (unbox (d-svc-seq svc))))
    (lambda (s result)
      (define text (result->doc-text result))
      (cond
        [(and (= seq (unbox (d-svc-seq svc))) text (live-view? s vid))
         (open-window! s svc vid text)]
        [else s]))))

;;; ---------- 事件 / 命令 ----------

;; 补全广播的选中项变化。新选中只记不做（O(1)，补全不等文档）；
;; 「无选中」（菜单关闭）则**立即**关窗（不涉及异步，不等）。
(define (docs-selection-hook s args)
  (define svc (docs-svc s))
  (cond
    [(not svc) s]
    [else
     (match-define (list vid name mods menu-rect) args)
     (cond
       [(or (not vid) (not name))
        (set-box! (d-svc-pending svc) #f)
        (set-box! (d-svc-last-key svc) #f)
        (close-docs s)]
       [else
        (set-box! (d-svc-menu-rect svc) menu-rect)
        (set-box! (d-svc-pending svc) (list vid name mods))
        s])]))

;; before-render：处理本帧收到的选中项（提交查询 / 关窗），全部在本插件内完成。
(define (docs-tick-hook s _args)
  (define svc (docs-svc s))
  (cond
    [(not svc) s]
    [else
     (define p (unbox (d-svc-pending svc)))
     (cond
       [(not p) s]
       [else
        (set-box! (d-svc-pending svc) #f)
        (match-define (list vid name mods) p)
        (cond
          [(or (not vid) (not name) (not (pair? mods)))
           (set-box! (d-svc-last-key svc) #f)
           (close-docs s)]
          [(equal? (list name mods) (unbox (d-svc-last-key svc))) s]
          [else
           (set-box! (d-svc-last-key svc) (list name mods))
           (request-docs! s svc vid name mods)])])]))

;; 滚动：delta > 0 向下看。
(define (docs-scroll-hook s args)
  (define svc (docs-svc s))
  (define dw (and svc (unbox (d-svc-win svc))))
  (cond
    [(not dw) s]
    [else
     (define delta (car args))
     (define n (length (docwin-lines dw)))
     (define rows (min n (doc-content-rows s)))
     (define max-off (max 0 (- n rows)))
     (define off (max 0 (min max-off (+ (docwin-offset dw) delta))))
     (set-box! (d-svc-win svc) (struct-copy docwin dw [offset off]))
     (refresh-doc-window! s)]))

;; Tab 切过来/切走：只改高亮（亮 / 暗）。
(define (docs-focus-hook s args)
  (define svc (docs-svc s))
  (cond
    [(not svc) s]
    [else (set-box! (d-svc-focus svc) (car args)) (refresh-doc-window! s)]))

;; M-d：对光标处标识符独立查询（不依赖补全）。
(define (cmd-show-docs s)
  (define svc (docs-svc s))
  (define vid (session-focus-vid s))
  (cond
    [(or (not svc) (not vid) (session-dock-vid? s vid)) s]
    [(not (racket-file? (session-file-path s (session-view-did s vid)))) s]
    [else
     (define text (session-view-string s vid))
     (define id (identifier-at text (session-view-point-line s vid) (session-view-point-column s vid)))
     (cond
       [(not id) (set-box! (d-svc-pending svc) (list vid #f #f)) s]
       [else
        (set-box! (d-svc-menu-rect svc) #f)              ; 独立触发：不避让
        (set-box! (d-svc-last-key svc) #f)
        (set-box! (d-svc-pending svc) (list vid id (cursor-mods s vid)))
        s])]))

;; 光标处标识符所在文件的模块上下文（#lang + require；无则 racket/base）。
(define (cursor-mods s vid)
  (define did (session-view-did s vid))
  (define path (session-file-path s did))
  (define text (session-view-string s vid))
  (define base-dir (or (and path (let-values ([(d _f _m) (split-path path)]) d))
                       (current-directory)))
  (define-values (lang forms) (requires-context text))
  (define mods (requires-of-forms lang forms #:base-dir base-dir))
  (if (null? mods) '(racket/base) mods))

;; 焦点移开 / 光标导航 → 关文档窗。
(define (docs-cancel-hook s _args)
  (define svc (docs-svc s))
  (if (and svc (unbox (d-svc-win svc))) (close-docs s) s))

;; 文档窗自己的 document 被关（外部）→ 清状态。
(define (docs-doc-closed-hook s args)
  (define svc (docs-svc s))
  (define did (car args))
  (define dw (and svc (unbox (d-svc-win svc))))
  (if (and dw (eqv? did (docwin-ddid dw))) (remove-doc-window! s) s))

(define (docs-handler)
  (lambda (s cmd)
    (cond
      [(cmd-docs-show? cmd) (cmd-show-docs s)]
      [else #f])))

;;; ---------- 注册 ----------

(define (docs-install s)
  (let* ([s0 (install-doc-job! s)]
         [svc (d-svc (box #f) (box 0) (box #f) (box #f) (box #f) (box #f))]
         [s1 (session-service-put s0 'docs svc)]
         [s2 (session-add-handler s1 (docs-handler))]
         [s3 (session-add-hook s2 (hook 'complete-selection docs-selection-hook))]
         [s4 (session-add-hook s3 (hook 'docs-scroll docs-scroll-hook))]
         [s5 (session-add-hook s4 (hook 'docs-focus docs-focus-hook))]
         [s6 (session-add-hook s5 (hook 'focus-changed docs-cancel-hook))]
         [s7 (session-add-hook s6 (hook 'after-nav docs-cancel-hook))]
         [s8 (session-add-hook s7 (hook 'document-closed docs-doc-closed-hook))])
    (session-add-hook s8 (hook 'before-render docs-tick-hook))))

(define docs-spec
  (plugin-spec 'docs docs-install '()))
