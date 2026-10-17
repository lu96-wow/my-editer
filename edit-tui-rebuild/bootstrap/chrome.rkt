#lang racket

;;; bootstrap/chrome.rkt —— 安装共享 chrome 槽：status bar + input bar（core buffer）
;;;
;;; 两个成员都是真正的 core view（buffer 支撑），放在同一个 region：
;;;   status-view : mode 'status，只读投影
;;;   input-view  : mode 'input，编辑输入
;;; active 决定当前显示哪个；输入结束切回 status。
;;;
;;; 本模块只负责“安装 / 切换显示”，不负责 prompt 逻辑。

(provide install-chrome!
         chrome-show-input chrome-show-status
         chrome-status-view chrome-input-view
         chrome-show-view
         input-view input-show input-finish input-read-text input-write-prompt
         sync-chrome!)

(require "../base/id.rkt"
         "../base/effect.rkt"
         "../base/transition.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/chrome.rkt"
         "../effects/engine.rkt"
         "../projection/status.rkt")

(define (install-chrome! engine state region-id #:status-mode [status-mode 'status])
  ;; status document/view
  (define-values (status-did s1) (state-next-id state 'doc))
  (define-values (status-vid s2) (state-next-id s1 'view))
  (void (engine-create-doc! engine status-did "*status*" ""))
  (void (engine-create-view! engine status-vid status-did))
  ;; input document/view
  (define-values (input-did s3) (state-next-id s2 'doc))
  (define-values (input-vid s4) (state-next-id s3 'view))
  (void (engine-create-doc! engine input-did "*input*" ""))
  (void (engine-create-view! engine input-vid input-did))

  (define ws (state-workspace s4))
  (define ws1 (workspace-add-doc ws status-did
                                 (make-doc-meta "*status*" #:mode status-mode)))
  (define ws2 (workspace-add-view ws1 status-vid (view-meta status-did (hash))))
  (define ws3 (workspace-add-doc ws2 input-did
                                 (make-doc-meta "*input*" #:mode 'input)))
  (define ws4 (workspace-add-view ws3 input-vid (view-meta input-did (hash))))
  (define reg (region region-id
                      (list (view-member status-vid) (view-member input-vid))
                      status-vid
                      'slot))
  (define ws5 (workspace-add-region ws4 region-id reg))
  (define s5 (state-set-workspace s4 ws5))
  (state-chrome* s5
                 (λ (c)
                   (chrome-set-slot c (make-chrome-slot region-id status-vid input-vid)))))

(define (chrome-slot* state)
  (chrome-slot-info (state-chrome state)))

(define (chrome-status-view state)
  (define s (chrome-slot* state))
  (and s (chrome-slot-status-view s)))

(define (chrome-input-view state)
  (define s (chrome-slot* state))
  (and s (chrome-slot-input-view s)))

(define (chrome-show-view state view-id)
  (define s (chrome-slot* state))
  (if (not s)
      state
      (state-workspace*
       state
       (λ (ws)
         (define reg (workspace-region ws (chrome-slot-region s)))
         (if reg
             (workspace-add-region ws (chrome-slot-region s)
                                   (struct-copy region reg [active view-id]))
             ws)))))

(define (chrome-show-input state)
  (define v (chrome-input-view state))
  (if v (chrome-show-view state v) state))

(define (chrome-show-status state)
  (define v (chrome-status-view state))
  (if v (chrome-show-view state v) state))


;;; ════════════════ input document ════════════════
;;;
;;; 输入栏 = *input* document 的 buffer：
;;;   · prompt 前缀写进 buffer，并用 readonly range 保护；
;;;   · 输入文本就是 buffer 里前缀之后的内容；
;;;   · 提交时读完整 buffer 字符串，交给 input-command 匹配。

(define (input-view state) (chrome-input-view state))

;; 切到 input 栏，写入 prompt（前缀只读），焦点移到 input view。
(define (input-show state prompt)
  (define vid (input-view state))
  (cond
    [(not vid) (transition-pure state)]
    [else
     (define s1 (state-set-focus (chrome-show-input state) vid))
     (transition s1 (list (set-input-prompt-effect vid prompt)))]))

;; 结束输入：切回 status，恢复进入前的焦点。
(define (input-finish state)
  (define s1 (chrome-show-status state))
  (state-workspace* s1 (λ (ws) (workspace-pop-focus ws))))

;; 输入栏完整字符串（含 prompt 前缀）。
(define (input-read-text state ev)
  (define vid (input-view state))
  (and vid (engine-view-view-text ev vid)))

;; 只改 prompt / 输入内容（输入过程中切换下一个确认项时用）。
(define (input-write-prompt state prompt)
  (define vid (input-view state))
  (if vid
      (transition state (list (set-input-prompt-effect vid prompt)))
      (transition-pure state)))

;;; ════════════════ status buffer 同步 ════════════════

;; 在渲染前把 status-line 写进 status view 的 buffer。
;; 只写 status view；input view 由 prompt 自己管。
(define (sync-chrome! state engine status-parts)
  (define sv (chrome-status-view state))
  (when sv
    (define ev (make-engine-view engine))
    (define ws (state-workspace state))
    (define did (workspace-doc-of-view ws sv))
    (define dm (and did (workspace-doc ws did)))
    (define text (if (and dm (eq? (doc-meta-mode dm) 'state))
                     (state-line state ev)
                     (status-line state ev status-parts)))
    (define cur (or (engine-view-view-text ev sv) ""))
    (unless (string=? text cur)
      (engine-set-view-text! engine sv text)))
  (void))
