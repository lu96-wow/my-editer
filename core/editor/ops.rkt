#lang racket

;;; editor/ops.rkt —— 纯轴算子 + 提交壳
;;;
;;;   · 纯算子：edit-op 是 (document × selections → 新值 + changes) 的纯函数 + 合并标签；
;;;             导航 / 视口都是纯函数。
;;;   · 提交壳：把纯结果写回 buffer/view（唯一可变处）。组织方式是
;;;             「文档算一次，然后 map 到该 buffer 的所有 view」。
;;;
;;; 操作是函数，组合用 compose，集合用 map；没有命令名注册表。

(require "state.rkt" "state-data.rkt" "history.rkt" "query.rkt"
         "../text/document.rkt" "../text/command.rkt" "../text/rebase.rkt"
         "../text/base/point.rkt" "../text/base/selection.rkt"
         "../text/base/range.rkt" "../text/base/change.rkt"
         "../text/base/track.rkt" "../text/base/line.rkt" "../text/base/width.rkt"
         "../view/base/viewport.rkt")

(provide
 ;; ---------- 纯：编辑算子 ----------
 (struct-out edit-op)             ; 纯函数 run
 op-type                          ; text → edit-op
 op-type-ignore-readonly          ; text → edit-op（不守只读）
 op-backspace                     ; → edit-op
 op-backspace-ignore-readonly     ; → edit-op
 op-delete                        ; → edit-op
 op-delete-ignore-readonly        ; → edit-op
 op-paste                         ; text → edit-op
 op-paste-ignore-readonly         ; text → edit-op

 ;; ---------- 提交：编辑 ----------
 buffer-edit!                     ; buffer view op [#:ensure?] → #f | (listof change)
 buffer-replace!                  ; buffer value [#:ensure? #:changes #:chunk-lines] → void
 buffer-replace-range!            ; buffer range text [#:ensure?] → #f | (listof change)
 buffer-set-line!                 ; buffer line text → #f | (listof change)
 buffer-set-char!                 ; buffer line col char/text → #f | (listof change)
 buffer-apply-if-version!         ; buffer base-doc new-doc → applied?（CAS）

 ;; ---------- 提交：undo 事务（显式合并） ----------
 buffer-begin-undo-step!          ; buffer → void（开始事务）
 buffer-end-undo-step!            ; buffer → void（结束事务，合成一步）
 buffer-with-undo-step            ; buffer thunk → void（事务块）

 ;; ---------- 提交：导航 ----------
 view-nav!                        ; view f [extend?] [#:ensure?] → void
 view-char-nav!                   ; view which extend? → void
 view-visual-nav!                 ; view up? extend? → void
 view-left!                       ; view [extend?] → void
 view-right!                      ; view [extend?] → void
 view-up!                         ; view [extend?] → void
 view-down!                       ; view [extend?] → void
 view-home!                       ; view [extend?] → void
 view-end!                        ; view [extend?] → void

 ;; ---------- 提交：选区 / 定位 ----------
 view-set-selections!             ; view sels [#:ensure?] → void
 view-set-point!                  ; view point → void
 view-select-all!                 ; view → void
 view-add-selection!              ; view selection [#:ensure?] → void
 view-remove-selection!           ; view selection [#:ensure?] → void

 ;; ---------- 提交：视口 ----------
 view-ensure!                     ; view → 滚到能看见主光标
 view-ensure-cursor-position!     ; view → 滚到主光标并返回其屏幕位置 (values row col)
 view-scroll!                     ; view delta → void
 view-set-mode!                   ; view mode → void
 view-toggle-line-numbers!        ; view → void
 view-resize!                     ; view w h → void（保持锚点）
 view-set-top-line!               ; view n → void
 view-set-left-column!            ; view n → void
 view-set-anchor!                 ; view line dc → void
 view-set-anchor-point!           ; view point → void

 ;; ---------- 读：复制 ----------
 view-copy-text                   ; view → 主选区文本
 view-selection-text              ; view selection → 该选区文本

 ;; ---------- 提交：历史 ----------
 buffer-undo!                     ; buffer → ok?
 buffer-redo!                     ; buffer → ok?
 buffer-clear-history!            ; buffer → void
 buffer-reset-history!            ; buffer [enabled?] → void
 buffer-set-history-enabled!)     ; buffer flag → void

;;; ================= undo 事务（显式合并） =================
;;;
;;; 合并完全显式：编辑本身不含任何并步策略（无 tag、无启发式）。
;;; 事务内：**第一次提交就 record**（立刻成为一个可见的撤销步），之后 merge 进它。
;;; 于是事务一旦有变更就已落栈，不会因忘记收步而丢失；无变更则不会留下空步。
;;; 嵌套：begin/end 按 depth 计数，最外层 end 才清事务。

(struct undo-scope (buffer pre depth created?) #:mutable)

(define current-undo-scopes (make-parameter '()))   ; (listof undo-scope)

(define (find-undo-scope b)
  (for/first ([s (in-list (current-undo-scopes))] #:when (eq? (undo-scope-buffer s) b)) s))
(define (in-undo-scope? b) (and (find-undo-scope b) #t))

(define (buffer-begin-undo-step! b)
  (define s (find-undo-scope b))
  (if s
      (set-undo-scope-depth! s (add1 (undo-scope-depth s)))
      (current-undo-scopes (cons (undo-scope b (buffer-document b) 1 #f)
                                 (current-undo-scopes)))))

;; 事务内的一次提交：首次 record，之后 merge（都只产生/延长一个步）。
(define (scope-commit! b doc*)
  (define s (find-undo-scope b))
  (cond
    [(undo-scope-created? s)
     (set-buffer-history! b (history-merge (buffer-history b) doc*))]
    [else
     (set-undo-scope-created?! s #t)
     (set-buffer-history! b (history-record (buffer-history b) (undo-scope-pre s) doc*))]))

(define (buffer-end-undo-step! b)
  (define s (find-undo-scope b))
  (when s
    (if (> (undo-scope-depth s) 1)
        (set-undo-scope-depth! s (sub1 (undo-scope-depth s)))
        (current-undo-scopes (remq s (current-undo-scopes))))))

(define (buffer-with-undo-step b thunk)
  (buffer-begin-undo-step! b)
  (dynamic-wind void thunk (lambda () (buffer-end-undo-step! b))))

;;; ================= 纯：编辑算子 =================

(struct edit-op (run) #:transparent)
;; run : document × selections → (values document selections changes ok?)

(define (op-type text) (edit-op (lambda (d s) (command-type d s text))))
(define (op-type-ignore-readonly text)
  (edit-op (lambda (d s) (command-type-ignore-readonly d s text))))

(define (op-backspace) (edit-op command-backspace))
(define (op-backspace-ignore-readonly) (edit-op command-backspace-ignore-readonly))
(define (op-delete) (edit-op command-delete))
(define (op-delete-ignore-readonly) (edit-op command-delete-ignore-readonly))

(define (op-paste text) (edit-op (lambda (d s) (command-paste d s text))))
(define (op-paste-ignore-readonly text)
  (edit-op (lambda (d s) (command-paste-ignore-readonly d s text))))

;;; ================= 提交：编辑 =================

;; 让视口包含主光标。
(define (view-ensure! v)
  (define p (selection-head (selections-primary (view-selections v))))
  (set-view-viewport! v (viewport-ensure (document-text (view-document v)) (view-viewport v) p)))

;; 夹到主光标，并返回夹好后它的屏幕位置（view 内坐标）。→ (values row col)
(define (view-ensure-cursor-position! v)
  (view-ensure! v)
  (view-cursor-screen-position v))

;; 把所有 view 的选区夹回合法域。
(define (buffer-clamp-views! b)
  (define t (document-text (buffer-document b)))
  (define n (track-length t))
  (for ([v (in-list (buffer-views b))])
    (set-view-selections! v (selections-clamp (view-selections v) n (curry track-line-length t)))))

;; 对一个 view 应用编辑算子；文档算一次，再 map 到所有 view。
;; 返回本次变更描述：
;;   #f          只读挡，未提交
;;   '()         提交成功但无变更
;;   (list change) 提交成功，含本次所有变更
;; 真值 = 已提交（含无变更），#f = 拒绝。
(define (buffer-edit! b v op #:ensure? [ensure? #t])
  (define h (buffer-history b))
  (define doc (history-document h))
  (define pre-sels (view-selections v))
  (define-values (doc* sels* changes ok?) ((edit-op-run op) doc pre-sels))
  (cond
    [(not ok?) #f]                                  ; 只读挡
    [(null? changes) '()]                           ; 无变更
    [else
     (if (in-undo-scope? b)
         (scope-commit! b doc*)                            ; 事务内：首次 record，之后 merge
         (set-buffer-history! b (history-record h doc doc*)))
     (set-view-selections! v sels*)                ; 发起视图：前进
     (for ([x (in-list (buffer-views b))] #:unless (eq? x v))   ; 兄弟视图：rebase
       (set-view-selections! x (selections-rebase changes (view-selections x))))
     (when ensure? (view-ensure! v))
     changes]))

;; 程序替换当前文档：不记步、封口、所有视图重定位。value = string | document。
(define (buffer-replace! b value
                         #:ensure? [ensure? #f]
                         #:changes [changes #f]
                         #:chunk-lines [chunk-lines default-chunk-lines])
  (define doc* (->document value chunk-lines))
  (define old (buffer-document b))
  (cond
    [(eq? doc* old) (void)]
    [else
     (set-buffer-history! b (history-set-current (buffer-history b) doc*))
     (if (and changes (pair? changes))
         (for ([v (in-list (buffer-views b))])
           (set-view-selections! v (selections-rebase changes (view-selections v)))
           (when ensure? (view-ensure! v)))
         (buffer-clamp-views! b))
     (void)]))

;; 程序区间替换：记一步、封口、所有视图按 changes 字面重定位。→ #f | (listof change)
;; 不守只读（程序级，与 buffer-replace! 一致）。
(define (buffer-replace-range! b r text #:ensure? [ensure? #f])
  (define r* (range-normalize r))
  (define doc (buffer-document b))
  (define-values (doc* ch ok?)
    (document-replace-ignore-readonly doc
      (point-line (range-start r*)) (point-column (range-start r*))
      (point-line (range-end r*))   (point-column (range-end r*))
      text))
  (cond
    [(not ok?) #f]
    [(or (not ch) (change-empty? ch)) '()]
    [else
     (if (in-undo-scope? b)
         (scope-commit! b doc*)
         (set-buffer-history! b (history-record (buffer-history b) doc doc*)))
     (for ([v (in-list (buffer-views b))])
       (set-view-selections! v (selections-rebase (list ch) (view-selections v)))
       (when ensure? (view-ensure! v)))
     (list ch)]))

;; 整行替换 / 单格替换（buffer-replace-range! 的糖）。行/列越界 → #f。
(define (buffer-set-line! b line text)
  (define t (document-text (buffer-document b)))
  (and (exact-nonnegative-integer? line) (< line (track-length t))
       (buffer-replace-range! b
         (range-of (point line 0) (point line (track-line-length t line)))
         text)))

(define (buffer-set-char! b line col ch)
  (define t (document-text (buffer-document b)))
  (and (exact-nonnegative-integer? line) (< line (track-length t))
       (exact-nonnegative-integer? col) (< col (track-line-length t line))
       (buffer-replace-range! b
         (range-of (point line col) (point line (add1 col)))
         (if (char? ch) (string ch) ch))))

;; 异步文本写（CAS）：base-doc 未变才装，记一步。→ applied?
(define (buffer-apply-if-version! b base-doc new-doc)
  (cond
    [(not (eq? (buffer-document b) base-doc)) #f]
    [else
     (if (in-undo-scope? b)
         (scope-commit! b new-doc)
         (set-buffer-history! b (history-record (buffer-history b) base-doc new-doc)))
     (buffer-clamp-views! b)
     #t]))

;;; ================= 提交：导航 =================

(define (view-nav! v f [extend? #f] #:ensure? [ensure? #t])
  (set-view-selections! v ((if extend? selections-extend selections-go) (view-selections v) f))
  (when ensure? (view-ensure! v)))

(define (view-char-nav! v which extend?)
  (define t (document-text (view-document v)))
  (define f (case which
              [(left)  (lambda (p) (point-left t p))]
              [(right) (lambda (p) (point-right t p))]
              [(home)  (lambda (p) (point-home t p))]
              [(end)   (lambda (p) (point-end t p))]))
  (view-nav! v f extend?))

(define (view-visual-nav! v up? extend?)
  (define t (document-text (view-document v)))
  (define vp (view-viewport v))
  (view-nav! v (lambda (p) ((if up? point-up point-down) t vp p)) extend?))

(define (view-left! v [extend? #f])  (view-char-nav! v 'left extend?))
(define (view-right! v [extend? #f]) (view-char-nav! v 'right extend?))
(define (view-home! v [extend? #f])  (view-char-nav! v 'home extend?))
(define (view-end! v [extend? #f])   (view-char-nav! v 'end extend?))
(define (view-up! v [extend? #f])    (view-visual-nav! v #t extend?))
(define (view-down! v [extend? #f])  (view-visual-nav! v #f extend?))

;;; ================= 提交：选区 / 定位 =================

(define (view-set-selections! v sels #:ensure? [ensure? #t])
  (define t (document-text (view-document v)))
  (define n (track-length t))
  (set-view-selections! v (selections-clamp sels n (curry track-line-length t)))
  (when ensure? (view-ensure! v)))

(define (view-set-point! v p) (view-set-selections! v (selections-one (caret p))))

(define (view-select-all! v)
  (define t (document-text (view-document v)))
  (define last (sub1 (track-length t)))
  (view-set-selections! v
    (selections-one (selection (point 0 0) (point last (track-line-length t last))))))

;; 多光标增 / 删一个选区（read-modify-write，内部 clamp）。
(define (view-add-selection! v s #:ensure? [ensure? #t])
  (view-set-selections! v (selections-add (view-selections v) (list s)) #:ensure? ensure?))
(define (view-remove-selection! v s #:ensure? [ensure? #t])
  (view-set-selections! v (selections-remove (view-selections v) (list s)) #:ensure? ensure?))

;;; ================= 提交：视口 =================

(define (view-scroll! v delta)
  (set-view-viewport! v (viewport-scroll (document-text (view-document v)) (view-viewport v) delta)))

;; 改视口字段的公共壳：先取当前锚点，改完落回同锚。
(define (view-viewport-update! v f)
  (define t (document-text (view-document v)))
  (define-values (line dc) (viewport-anchor t (view-viewport v)))
  (set-view-viewport! v (viewport-set-anchor t (f (view-viewport v)) line dc)))

(define (view-set-mode! v mode)
  (view-viewport-update! v (lambda (vp) (viewport-set-mode vp mode))))
(define (view-toggle-line-numbers! v)
  (view-viewport-update! v (lambda (vp) (viewport-set-line-numbers vp (not (viewport-line-numbers? vp))))))
(define (view-resize! v width height)
  (view-viewport-update! v (lambda (vp) (viewport-set-size vp width height))))
(define (view-set-top-line! v n)
  (set-view-viewport! v (viewport-set-top-line (view-viewport v) n)))
(define (view-set-left-column! v n)
  (set-view-viewport! v (viewport-set-left-column (document-text (view-document v)) (view-viewport v) n)))
(define (view-set-anchor! v line dc)
  (set-view-viewport! v (viewport-set-anchor (document-text (view-document v)) (view-viewport v) line dc)))
(define (view-set-anchor-point! v p)
  (define t (document-text (view-document v)))
  (define n (track-length t))
  (define line (max 0 (min (point-line p) (sub1 n))))
  (define s (track-ref t line))
  (define col (max 0 (min (point-column p) (string-length s))))
  (set-view-viewport! v (viewport-set-anchor t (view-viewport v) line (index->display-column s col))))

;;; ================= 读：复制 =================

(define (view-copy-text v)
  (define doc (view-document v))
  (define s (selections-primary (view-selections v)))
  (define-values (a b) (selection-range s))
  (document-copy doc (point-line a) (point-column a) (point-line b) (point-column b)))

;; 指定选区的文本。
(define (view-selection-text v s)
  (define doc (view-document v))
  (define-values (a b) (selection-range s))
  (document-copy doc (point-line a) (point-column a) (point-line b) (point-column b)))

;;; ================= 提交：历史 =================

(define (buffer-undo! b)
  (define-values (h* ok?) (history-undo (buffer-history b)))
  (cond [(not ok?) #f]
        [else (set-buffer-history! b h*) (buffer-clamp-views! b) #t]))

(define (buffer-redo! b)
  (define-values (h* ok?) (history-redo (buffer-history b)))
  (cond [(not ok?) #f]
        [else (set-buffer-history! b h*) (buffer-clamp-views! b) #t]))

(define (buffer-clear-history! b)
  (set-buffer-history! b (history-clear (buffer-history b))))
(define (buffer-reset-history! b [enabled? #f])
  (set-buffer-history! b (history-set-enabled (history-clear (buffer-history b)) enabled?)))
(define (buffer-set-history-enabled! b flag)
  (set-buffer-history! b (history-set-enabled (buffer-history b) flag)))
