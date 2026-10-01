#lang racket

(require "state.rkt" "write.rkt" "sync.rkt" "view.rkt"
         "../text/document.rkt" "history.rkt" "../text/command.rkt"
         "../text/base/point.rkt" "../text/base/selection.rkt"
         "../text/base/track.rkt" "../text/base/line.rkt" "../text/base/range.rkt"
         "../view/base/viewport.rkt")

;;; editor/command.rkt —— 用户命令：编辑 / 导航 / 撤销 / 重做
;;;
;;; 命名：全部按 vid（`editor-view-*`）；**无焦点糖**（焦点由宿主自理）。
;;;
;;;   编辑     所有内容变化都走 editor-view-set；editor-view-edit = set + history-record。
;;;            带 changes → 同文档其它视图 **rebase**（字面）；不带 → 只 **clamp**。
;;;            changes 为空 = 无实际变更（如文首退格）：不记步、不动选区，原样返回。
;;;   视口     每次改动某视图视口后（编辑 / 导航 / 滚动 / 定位 / 切 mode / 尺寸）
;;;            调 editor-sync-viewports：sync='follow / link 相同的视图跟随。
;;;   作者态   高亮 / readonly：**就地**改 document 的 box（不记步、不换 document），
;;;            并同步 history 的 current（document/who/selections），使作者态随快照搭车：
;;;            文本 undo/redo 恢复的快照里带着那一刻的高亮 / 只读。
;;;            注意：属性是**就地**改的，editor-view-set 的 eq? 检测看不到它，
;;;            所以作者态必须走 editor-view-author-edit，不能走 editor-view-set。
;;;            异步结果（LSP 高亮 / 诊断）可直接改句柄（editor/attributes.rkt），O(1)。
;;;   导航     只动选区 + ensure；不记步。
;;;   撤销/重做  换文档 + 还原发起视图的选区；**不动视口**（pin）。
;;;            undo/redo 没有变更描述 → 同文档其它视图的选区只做一次 clamp（防越界）。
;;;
;;; **合并**：history 是哑栈（一次 record = 一步）；**是否合并由调用方传给命令的 merge-tag 决定**。
;;; editor 只校验**合法性**（能并的充要条件）：
;;;     tag ≠ #f  ∧  tag = 变化前 tip.merge-tag  ∧  who = tip.who  ∧  pre-sels = tip.selections
;;;   · 同 who 是合法性约束：一步只能还原一个发起视图的选区；
;;;   · 「选区未动」是连续性约束（导航 / 装选区后自动断并）；
;;;   · 形状不做限制——并了 undo/redo 永远正确（快照模型），只是粒度变粗。
;;; 命中 → history-merge（折叠）；否则一个操作一条。命令本身**不预设**任何 tag。
;;; 另有 editor-view-seal：把当前段**封口**（清 tag，不新增步）—— 一段的终点。

(provide
;; ---------- 通用变更原语 ----------
 (struct-out step)
 editor-view-set editor-history-record editor-view-assign

;; ---------- 编辑 ----------
 editor-view-edit
 editor-view-insert
 editor-view-insert-ignore-readonly
 editor-view-backspace
 editor-view-backspace-ignore-readonly
 editor-view-delete
 editor-view-delete-ignore-readonly

;; ---------- 剪贴板 ----------
 editor-view-copy
 editor-view-cut
 editor-view-cut-ignore-readonly
 editor-view-paste
 editor-view-paste-ignore-readonly
 editor-view-paste-text
 editor-view-paste-text-ignore-readonly

;; ---------- 导航 ----------
 editor-view-left
 editor-view-right
 editor-view-up
 editor-view-down
 editor-view-home
 editor-view-end

;; ---------- 选区 / 定位 ----------
 editor-view-set-selections
 editor-view-select-all
 editor-view-set-point
 editor-view-goto

;; ---------- 滚动 / 视口 ----------
 editor-view-scroll
 editor-view-set-top-line
 editor-view-set-left-col
 editor-view-set-mode
 editor-view-toggle-line-numbers
 editor-view-set-size

;; ---------- 属性（作者态） ----------
 editor-view-highlight
 editor-view-highlight-range
 editor-view-highlight-cell
 editor-view-highlight-line
 editor-view-highlight-selections
 editor-view-highlight-batch
 editor-view-highlight-range-batch
 editor-view-readonly
 editor-view-readonly-range
 editor-view-readonly-cell
 editor-view-readonly-line
 editor-view-readonly-selections
 editor-view-readonly-batch
 editor-view-readonly-range-batch

;; ---------- 历史 ----------
 editor-view-undo
 editor-view-redo
 editor-view-clear-history
 editor-view-reset-history
 editor-view-seal)

;;; ---------- 编辑 ----------
;;;
;;; 编辑命令返回 (values editor (listof change))：
;;;     editor  新 editor（未变则 eq? 原值）；change = 本次变更描述（编辑前坐标）。
;;;     失败（被只读拒绝）/ 无实际变更（如文首退格）时 changes = '()。

;;; ---------- 通用变更原语 ----------
;;;
;;; 所有内容变化都走 editor-view-set：写内容 + 传播视图。
;;; step = 本次内容变化（前态/后态 + who=vid）；新值 eq? 旧值（无实际变化）时 #f。
;;; changes 给了 → 同文档其它视图 rebase(changes)；不给(#f) → 只 clamp。
;;; 是否进账本由调用方决定：调 editor-history-record 才记（属性 / widget 不调）。
;;; undo/redo 是「从账本取值 → 换内容 + clamp」的特例（还要移动账本指针，单独实现）。

(struct step (pre-value pre-sels post-value post-sels who pre-tip) #:transparent)

(define (editor-view-set ed vid value
                         #:selections [sels #f]
                         #:change [changes #f]
                         #:ensure? [ensure? #t])
  (define v (editor-view-ref ed vid))
  (define did (view-did v))
  (define e (editor-document-entry ed did))
  (define old (document-entry-document e))
  (cond
    [(eq? value old) (values ed #f)]
    [else
     (define t (document-text value))
     (define n (track-length t))
     (define (line-len l) (line-length (track-ref t l)))
     (define sels* (selections-clamp (or sels (view-selections v)) n line-len))
     (define pre-tip (history-current (document-entry-history e)))   ; set 之前先抓
     (define v* (struct-copy view v [selections sels*]))
     (define v** (if ensure? (view-ensure value v*) v*))
     ;; 1) 换视图；2) 内容写到账本栈顶（保留 merge-tag，赋值/属性不打断打字段）；3) 传播其它视图
     (define ed1 (editor-set-view ed v**))
     (define ed2 (editor-set-history ed1 did
                   (history-set-current (document-entry-history e) value sels* vid)))
     (define ed3 (if (and changes (pair? changes))
                     (editor-views-rebase ed2 did vid changes)
                     (editor-views-clamp ed2 did)))
     (define ed4 (editor-sync-viewports ed3 vid))
     (values ed4 (step old (view-selections v) value sels* vid pre-tip))]))

;; 把一次 step 记进账本：按「merge-tag + 同 who + 选区未动」判并入当前步还是新起一步；
;; step=#f / 账本关闭 时按开关策略（关闭：只推进，不记、清 future、封 tag）。
(define (editor-history-record ed did step [merge-tag #f])
  (cond
    [(not step) ed]
    [else
     (define e (editor-document-entry ed did))
     (define h (document-entry-history e))
     (define pre-tip (step-pre-tip step))
     (define pre-sels (step-pre-sels step))
     (define post-value (step-post-value step))
     (define post-sels (step-post-sels step))
     (define who (step-who step))
     (define merge? (and merge-tag
                         (equal? merge-tag (snapshot-merge-tag pre-tip))
                         (equal? who (snapshot-who pre-tip))
                         (equal? pre-sels (snapshot-selections pre-tip))))
     (define h* (cond
                  [merge? (history-merge h post-value post-sels)]
                  [else (history-record h (step-pre-value step) pre-sels
                                        post-value post-sels who merge-tag)]))
     (editor-set-history ed did h*)]))

;; 程序赋值（widget / 状态投影）：无 change（只 clamp）、不记步、默认不 ensure。
;; 整篇替换后把合并段**封口**：之后的编辑不会跨过这次赋值并进旧步。
(define (editor-view-assign ed vid value #:selections [sels #f] #:ensure? [ensure? #f])
  (define did (view-did (editor-view-ref ed vid)))
  (define-values (ed* step) (editor-view-set ed vid value #:selections sels #:change #f #:ensure? ensure?))
  (cond
    [(not step) ed*]
    [else (editor-set-history ed* did
            (history-seal (document-entry-history (editor-document-entry ed* did))))]))

;;; ---------- 编辑命令 ----------
;;;
;;; 编辑命令返回 (values editor (listof change))；
;;;     editor  新 editor（未变则 eq? 原值）；change = 本次变更描述（编辑前坐标）。
;;;     失败（被只读拒绝）/ 无实际变更（如文首退格）时 changes = '()。

;; 对某视图施加 op：成功则 set 内容 + 记一步。merge-tag 决定并入还是新起（见上）。
(define (editor-view-edit ed vid op [merge-tag #f] [ensure? #t])
  (define v (editor-view-ref ed vid))
  (define did (view-did v))
  (define e (editor-document-entry ed did))
  (define-values (doc* sels* changes ok?) (op (document-entry-document e) (view-selections v)))
  (cond
    [(not ok?) (values ed '())]
    [(null? changes) (values ed '())]
    [else
     (define-values (ed* step) (editor-view-set ed vid doc*
                                                #:selections sels*
                                                #:change changes
                                                #:ensure? ensure?))
     (cond
       [(not step) (values ed '())]
       [else (values (editor-history-record ed* did step merge-tag) changes)])]))


;;; ---------- 视图维护（ensure / 选区传播）见 editor/view.rkt ----------

;; 插入文本（指定视图的所有选区）：**不预设合并**；merge-tag 由调用方给（#f = 一步一条）。
(define (editor-view-insert ed vid text [merge-tag #f])
  (editor-view-edit ed vid (lambda (d s) (command-type d s text)) merge-tag))
(define (editor-view-backspace ed vid [merge-tag #f])
  (editor-view-edit ed vid command-backspace merge-tag))
(define (editor-view-delete ed vid [merge-tag #f])
  (editor-view-edit ed vid command-delete merge-tag))


;; 程序编辑（不守只读）：与守版同形，只是 op 换成 command-*-ignore-readonly。
;; **记不记步仍由该文档的 history 开关决定**（widget 关掉历史 → 不进撤销栈）。
(define (editor-view-insert-ignore-readonly ed vid text [merge-tag #f])
  (editor-view-edit ed vid (lambda (d s) (command-type-ignore-readonly d s text)) merge-tag))
(define (editor-view-backspace-ignore-readonly ed vid [merge-tag #f])
  (editor-view-edit ed vid command-backspace-ignore-readonly merge-tag))
(define (editor-view-delete-ignore-readonly ed vid [merge-tag #f])
  (editor-view-edit ed vid command-delete-ignore-readonly merge-tag))


;;; ---------- 选区（程序面：直接装选区，不记步） ----------

;; 给某视图装一套选区：先夹进文档合法域，再 ensure 主光标 + 同步跟随者。
(define (editor-view-set-selections ed vid sels #:ensure? [ensure? #t])
  (define v (editor-view-ref ed vid))
  (define did (view-did v))
  (define doc (document-entry-document (editor-document-entry ed did)))
  (define t (document-text doc))
  (define n (track-length t))
  (define (line-len l) (line-length (track-ref t l)))
  (define v* (struct-copy view v [selections (selections-clamp sels n line-len)]))
  (define v** (if ensure? (view-ensure doc v*) v*))
  (editor-sync-viewports (editor-set-view ed v**) vid))


;; 全选某视图的文档。
(define (editor-view-select-all ed vid)
  (define t (document-text (editor-view-document ed vid)))
  (define last (sub1 (track-length t)))
  (editor-view-set-selections ed vid
    (selections-one (selection (point 0 0) (point last (line-length (track-ref t last)))))))

(define (editor-view-set-point ed vid p)
  (editor-view-set-selections ed vid (selections-one (caret p))))

;;; ---------- 导航 ----------

;; 在指定视图上施加 point->point：装选区 + ensure + 同步跟随者。不记步。
(define (editor-view-nav ed vid f extend?)
  (define v (editor-view-ref ed vid))
  (define did (view-did v))
  (define doc (document-entry-document (editor-document-entry ed did)))
  (define sels* ((if extend? selections-extend selections-go) (view-selections v) f))
  (define v* (view-ensure doc (struct-copy view v [selections sels*])))
  (editor-sync-viewports (editor-set-view ed v*) vid))

;; 字符级导航（左/右/行首/行尾）：只需一行的文本。
(define (editor-view-char-nav ed vid which extend?)
  (define t (document-text (editor-view-document ed vid)))
  (define f (case which
              [(left) (lambda (p) (point-left t p))]
              [(right) (lambda (p) (point-right t p))]
              [(home) (lambda (p) (point-home t p))]
              [(end) (lambda (p) (point-end t p))]))
  (editor-view-nav ed vid f extend?))

(define (editor-view-left ed vid [extend? #f]) (editor-view-char-nav ed vid 'left extend?))
(define (editor-view-right ed vid [extend? #f]) (editor-view-char-nav ed vid 'right extend?))
(define (editor-view-home ed vid [extend? #f]) (editor-view-char-nav ed vid 'home extend?))
(define (editor-view-end ed vid [extend? #f]) (editor-view-char-nav ed vid 'end extend?))

;; 视觉行导航（上/下）：依赖该视图的 mode / 宽度。
(define (editor-view-visual-nav ed vid up? extend?)
  (define t (document-text (editor-view-document ed vid)))
  (define vp (view-viewport (editor-view-ref ed vid)))
  (editor-view-nav ed vid (lambda (p) ((if up? point-up point-down) t vp p)) extend?))

(define (editor-view-up ed vid [extend? #f]) (editor-view-visual-nav ed vid #t extend?))
(define (editor-view-down ed vid [extend? #f]) (editor-view-visual-nav ed vid #f extend?))


;; 滚动：只动指定视口，跟随者同步。
(define (editor-view-scroll ed vid delta)
  (define v (editor-view-ref ed vid))
  (define t (document-text (editor-view-document ed vid)))
  (editor-sync-viewports
   (editor-set-view ed (struct-copy view v [viewport (viewport-scroll t (view-viewport v) delta)]))
   vid))

;; 定位到点（鼠标）：折成该点处光标 + ensure。语义别名 = editor-set-point / editor-view-set-point。
(define (editor-view-goto ed vid p) (editor-view-set-point ed vid p))

;;; ---------- 视口设置 ----------

;; 切 mode：先按旧 mode 取锚点，再按新 mode 落回同锚（水平位置不丢）。
(define (editor-view-set-mode ed vid mode)
  (define v (editor-view-ref ed vid))
  (define t (document-text (editor-view-document ed vid)))
  (define-values (line dc) (viewport-anchor t (view-viewport v)))
  (define vp* (viewport-set-anchor t (viewport-set-mode (view-viewport v) mode) line dc))
  (editor-sync-viewports (editor-set-view ed (struct-copy view v [viewport vp*])) vid))


(define (editor-view-toggle-line-numbers ed vid)
  (define v (editor-view-ref ed vid))
  (define t (document-text (editor-view-document ed vid)))
  (define-values (line dc) (viewport-anchor t (view-viewport v)))
  (define vp* (viewport-set-anchor
               t
               (viewport-set-line-numbers (view-viewport v)
                                          (not (viewport-line-numbers? (view-viewport v))))
               line dc))
  (editor-sync-viewports (editor-set-view ed (struct-copy view v [viewport vp*])) vid))


;; 显式滚到某行 / 某显示列（程序面；同步跟随者）。
(define (editor-view-set-top-line ed vid n)
  (define v (editor-view-ref ed vid))
  (editor-sync-viewports
   (editor-set-view ed (struct-copy view v [viewport (viewport-set-top-line (view-viewport v) n)]))
   vid))

(define (editor-view-set-left-col ed vid n)
  (define v (editor-view-ref ed vid))
  (define t (document-text (editor-view-document ed vid)))
  (editor-sync-viewports
   (editor-set-view ed (struct-copy view v [viewport (viewport-set-left-col t (view-viewport v) n)]))
   vid))


;;; ---------- 撤销 / 重做（按 vid 所属 document） ----------

(define (editor-view-undo ed vid)
  (define v (editor-view-ref ed vid))
  (define did (view-did v))
  (define-values (hist* ok?) (history-undo (editor-document-history ed did)))
  (cond
    [(not ok?) ed]
    [else
     (define-values (_doc sels* who) (history-state hist*))
     (define ed* (editor-views-clamp (editor-set-history ed did hist*) did))
     ;; 把选区还原到发起视图（若还在）；不动视口
     (cond
       [(and who (for/or ([x (in-list (editor-views ed*))] #:when (= (view-id x) who)) #t))
        (editor-set-view ed* (struct-copy view (editor-view-ref ed* who) [selections sels*]))]
       [else ed*])]))

(define (editor-view-redo ed vid)
  (define v (editor-view-ref ed vid))
  (define did (view-did v))
  (define-values (hist* ok?) (history-redo (editor-document-history ed did)))
  (cond
    [(not ok?) ed]
    [else
     (define-values (_doc sels* who) (history-state hist*))
     (define ed* (editor-views-clamp (editor-set-history ed did hist*) did))
     (cond
       [(and who (for/or ([x (in-list (editor-views ed*))] #:when (= (view-id x) who)) #t))
        (editor-set-view ed* (struct-copy view (editor-view-ref ed* who) [selections sels*]))]
       [else ed*])]))

;; 清掉指定视图所属文档的撤销 / 重做栈（只留当前快照）。
(define (editor-view-clear-history ed vid)
  (define did (view-did (editor-view-ref ed vid)))
  (editor-set-history ed did (history-clear (editor-document-history ed did))))

;; 清栈 + 设定记步开关（一步完成）。状态栏输入结束：保留当前内容，关历史、清空。
(define (editor-view-reset-history ed vid [enabled? #f])
  (define did (view-did (editor-view-ref ed vid)))
  (editor-set-history ed did
                      (history-set-enabled (history-clear (editor-document-history ed did)) enabled?)))

;; 封口指定视图所属文档的当前合并段（不记步）：之后的编辑即使同 tag 也开新步。
(define (editor-view-seal ed vid)
  (define did (view-did (editor-view-ref ed vid)))
  (editor-set-history ed did (history-seal (editor-document-history ed did))))

;;; ---------- 剪贴板（editor 层：跨文档共享） ----------

;; 复制指定视图的**主选区**到 editor 剪贴板（不改文档、不记步）。
(define (editor-view-copy ed vid)
  (define v (editor-view-ref ed vid))
  (define doc (document-entry-document (editor-document-entry ed (view-did v))))
  (define s (selections-primary (view-selections v)))
  (define-values (a b) (selection-range s))
  (struct-copy editor ed
    [clipboard (document-copy doc (point-line a) (point-col a) (point-line b) (point-col b))]))

;; 把 editor 剪贴板粘到指定视图的**所有选区**（多光标富粘贴）；空剪贴板 = 不动。
(define (editor-view-paste ed vid [merge-tag #f])
  (define cp (editor-clipboard ed))
  (cond
    [(not cp) (values ed '())]
    [else (editor-view-edit ed vid (lambda (d s) (command-paste d s cp)) merge-tag)]))

;; 粘入**外部文本**（系统剪贴板）：造纯文本 clipboard（属性全 default）再走同一条粘贴路径。
(define (editor-view-paste-text ed vid text [merge-tag #f])
  (editor-view-edit ed vid (lambda (d s) (command-paste d s (clipboard-of-text text))) merge-tag))

;; 剪切：复制主选区 + 删除所有**非空**选区（多光标下剪贴板只含主选区）。
(define (editor-view-cut ed vid [merge-tag #f])
  (define v (editor-view-ref ed vid))
  (cond
    [(for/or ([s (in-list (selections-items (view-selections v)))]) (not (selection-empty? s)))
     (editor-view-edit (editor-view-copy ed vid) vid (lambda (d ss) (command-delete d ss)) merge-tag)]
    [else (values ed '())]))

;; 程序版（不守只读）；与守版同形。
(define (editor-view-paste-ignore-readonly ed vid [merge-tag #f])
  (define cp (editor-clipboard ed))
  (cond
    [(not cp) (values ed '())]
    [else (editor-view-edit ed vid (lambda (d s) (command-paste-ignore-readonly d s cp)) merge-tag)]))

(define (editor-view-paste-text-ignore-readonly ed vid text [merge-tag #f])
  (editor-view-edit ed vid (lambda (d s) (command-paste-ignore-readonly d s (clipboard-of-text text))) merge-tag))

(define (editor-view-cut-ignore-readonly ed vid [merge-tag #f])
  (define v (editor-view-ref ed vid))
  (cond
    [(for/or ([s (in-list (selections-items (view-selections v)))]) (not (selection-empty? s)))
     (editor-view-edit (editor-view-copy ed vid) vid (lambda (d ss) (command-delete-ignore-readonly d ss)) merge-tag)]
    [else (values ed '())]))

;;; ---------- 属性（作者态：不记步，随快照搭车） ----------

;; 改指定视图的文档但不记步。属性是**就地**改在 document 的 box 里（doc* 通常 eq? 原文档），
;; 这里只需把 current 的 (document, selections, who) 同步成发起作者态的视图，保持
;; "作者态随快照搭车 + undo/redo 还到发起视图" 的语义（O(1)，不新增步）。
(define (editor-view-author-edit ed vid op [ensure? #f])
  (define v (editor-view-ref ed vid))
  (define did (view-did v))
  (define e (editor-document-entry ed did))
  (define-values (doc* sels* ok?) (op (document-entry-document e) (view-selections v)))
  (cond
    [(not ok?) ed]
    [else
     (define ed* (editor-set-history ed did
                    (history-set-current (document-entry-history e) doc* sels* vid)))
     ;; 选区 / ensure（作者态一般不动选区；保持通用）
     (if (and (not ensure?) (equal? sels* (view-selections v)))
         ed*
         (editor-view-set-selections ed* vid sels* #:ensure? ensure?))]))

;; op : document × l0 c0 l1 c1 → document（区间填充）。
(define (editor-fill l0 c0 l1 c1 op)
  (lambda (d s) (values (op d l0 c0 l1 c1) s #t)))

;; 对**显式区间** r（规范化后）做作者态填充：不记步，只同步 history 的 current。
(define (editor-view-author-fill-range ed vid r op)
  (define r* (range-normalize r))
  (editor-view-author-edit ed vid
    (editor-fill (point-line (range-start r*)) (point-col (range-start r*))
                 (point-line (range-end r*))   (point-col (range-end r*))
                 op)))

;; 对**主选区**做作者态填充（旧名用；区间版是 -range）。
(define (editor-view-author-fill-selection ed vid op)
  (define-values (a b) (selection-range (selections-primary (view-selections (editor-view-ref ed vid)))))
  (editor-view-author-fill-range ed vid (range-of a b) op))

(define (editor-view-highlight-range ed vid r face)
  (editor-view-author-fill-range ed vid r (lambda (d l0 c0 l1 c1) (document-highlight-fill d l0 c0 l1 c1 face))))

(define (editor-view-readonly-range ed vid r flag)
  (editor-view-author-fill-range ed vid r (lambda (d l0 c0 l1 c1) (document-readonly-fill d l0 c0 l1 c1 flag))))

(define (editor-view-highlight ed vid face)
  (editor-view-author-fill-selection ed vid (lambda (d l0 c0 l1 c1) (document-highlight-fill d l0 c0 l1 c1 face))))

(define (editor-view-readonly ed vid flag)
  (editor-view-author-fill-selection ed vid (lambda (d l0 c0 l1 c1) (document-readonly-fill d l0 c0 l1 c1 flag))))

;; 单格 / 整行 / 全部选区 的赋值糖（都走作者态：不记步）。
(define (editor-view-highlight-cell ed vid line col face)
  (define len (line-length (track-ref (document-text (editor-view-document ed vid)) line)))
  (if (>= col len) ed
      (editor-view-highlight-range ed vid (range-of (point line col) (point line (add1 col))) face)))
(define (editor-view-readonly-cell ed vid line col flag)
  (define len (line-length (track-ref (document-text (editor-view-document ed vid)) line)))
  (if (>= col len) ed
      (editor-view-readonly-range ed vid (range-of (point line col) (point line (add1 col))) flag)))

(define (editor-view-highlight-line ed vid line face)
  (define len (line-length (track-ref (document-text (editor-view-document ed vid)) line)))
  (editor-view-highlight-range ed vid (range-of (point line 0) (point line len)) face))
(define (editor-view-readonly-line ed vid line flag)
  (define len (line-length (track-ref (document-text (editor-view-document ed vid)) line)))
  (editor-view-readonly-range ed vid (range-of (point line 0) (point line len)) flag))

;; 对**所有选区**写（多光标）。
(define (editor-view-highlight-selections ed vid face)
  (editor-view-author-edit ed vid
    (lambda (d s)
      (values (for/fold ([d d]) ([sel (in-list (selections-items s))])
                (let-values ([(a b) (selection-range sel)])
                  (document-highlight-fill d (point-line a) (point-col a) (point-line b) (point-col b) face)))
              s #t))))
(define (editor-view-readonly-selections ed vid flag)
  (editor-view-author-edit ed vid
    (lambda (d s)
      (values (for/fold ([d d]) ([sel (in-list (selections-items s))])
                (let-values ([(a b) (selection-range sel)])
                  (document-readonly-fill d (point-line a) (point-col a) (point-line b) (point-col b) flag)))
              s #t))))

;; 批量：fills : (listof (list l0 c0 l1 c1 val))，一次 materialize、一次写 box。
;; 作者态（不记步）；与逐个调用 editor-view-highlight-range 等价，但只 materialize 一次。
(define (editor-view-highlight-batch ed vid fills)
  (editor-view-author-edit ed vid
    (lambda (d s) (values (document-highlight-fill-batch d fills) s #t))))
(define (editor-view-readonly-batch ed vid fills)
  (editor-view-author-edit ed vid
    (lambda (d s) (values (document-readonly-fill-batch d fills) s #t))))

;; 批量（range 版）：runs : (listof (list range val))。range 先规范化。
(define (editor-view-highlight-range-batch ed vid runs)
  (editor-view-author-edit ed vid
    (lambda (d s) (values (document-highlight-fill-range-batch d runs) s #t))))
(define (editor-view-readonly-range-batch ed vid runs)
  (editor-view-author-edit ed vid
    (lambda (d s) (values (document-readonly-fill-range-batch d runs) s #t))))

;;; ---------- 视图尺寸 ----------

;; 设定某个视图的尺寸（重锚，保住水平位置），并同步跟随者。
(define (editor-view-set-size ed vid width height)
  (define v (editor-view-ref ed vid))
  (define t (document-text (editor-view-document ed vid)))
  (define-values (line dc) (viewport-anchor t (view-viewport v)))
  (define vp* (viewport-set-anchor t (viewport-set-size (view-viewport v) width height) line dc))
  (editor-sync-viewports (editor-set-view ed (struct-copy view v [viewport vp*])) vid))


;;; ---------- 投影（单视图 / 多视图）在 render.rkt ----------
