#lang racket

;;; api-temp/api/1-edit.rkt —— 底层原理 · 编辑
;;;
;;; 只讲 core/api.rkt（低层公开面）里的东西：point / selection / selection-set /
;;; edit-desc / change / buffer / document / 事件。
;;; 「编辑器」层面的命令（editor-*）在 api-temp/editor/，本文件**不 require editor.rkt**。
;;;
;;; 底层四层的分工（理解这个，各 API 的归属就清楚了）：
;;;   atom    point / selection / edit-desc / change      纯值 + 代数，不认识文本容器
;;;   unit    attrs / history                              属性 buffer、账本
;;;   doc     buffer = 文本+tick；document = buffer+attrs   编辑施加的唯一漏斗
;;;   viewport window / screen                             视口与帧（见 api/3-render.rkt）
;;;   platform editor-*                                    把上面拼成「编辑器」（见 editor/）
;;;
;;; 三种「编辑动作 op」的形状（最容易搞混，先记住）：
;;;   buffer op  : buffer selection → edit-desc       （buffer-op-*；喂 document-edit-at）
;;;   edit-desc  : 具体的一次替换 [start,end)→new-text（喂 document-apply-edit）
;;;   editor op  : editor did selection → edit-desc   （edit-*；见 api-temp/editor/）
;;;
;;; 运行：racket api-temp/api/1-edit.rkt

(require "../../core/api.rkt")

(define (show label v) (printf "~a\n    => ~v\n" label v))
(define (header s) (printf "\n========== ~a ==========\n" s))
(define (P l c) (point l c))

;;; ===========================================================================
(header "1. point —— 位置（core 里唯一的位置表示，0-based）")
;;; ===========================================================================

;; point : nat nat → point
;;   设计：位置只有这一种表示，任何「要位置」的函数收 point、「给位置」的返回 point ——
;;         避免出现「两个裸数字谁先谁后」的约定错误。
;;         point **不知道**它所在行多长（所以合法性由 point-clamp 单独保证）。
;;   用法：构造 (point line col)；line/col 都 0-based；col 是**字符索引**（不是显示列）。
(show "(point 2 3)" (P 2 3))
(show "(point-line (point 2 3))" (point-line (P 2 3)))
(show "(point-col  (point 2 3))" (point-col (P 2 3)))
(show "(point? (point 2 3))" (point? (P 2 3)))

;; point<? point=? point<=? : point point → boolean
;;   设计：位置比较只有一份实现（pos<?/pos=/pos<=?）；这三个是 point 包装。
;;   用法：排序、区间判断、半开区间 [start,end) 比较。
(show "(point<? (point 1 9) (point 2 0))" (point<? (P 1 9) (P 2 0)))
(show "(point=? (point 2 3) (point 2 3))" (point=? (P 2 3) (P 2 3)))
(show "(point<=? (point 2 3) (point 2 3))" (point<=? (P 2 3) (P 2 3)))

;; pos<? pos=? pos<=? : nat nat nat nat → boolean
;;   设计：给「还没构造 point 的裸输入」（比如鼠标坐标计算）用，省一次构造。
(show "(pos<? 0 5 1 0)" (pos<? 0 5 1 0))

;; point-clamp : point nat (nat → nat) → point
;;   设计：point 本身不含行信息，所以夹紧要外部提供「总行数 + 每行长度函数」。
;;         行越界夹到末行；列越界夹到该行长度；负值归 0。
;;   用法：任何外来位置（鼠标、LSP、上次保存的光标）在进入 core 前先夹紧。
(show "(point-clamp (point 9 9) 3 行长(2,3,5))"
      (point-clamp (P 9 9) 3 (lambda (l) (list-ref '(2 3 5) l))))

;;; ===========================================================================
(header "2. selection —— 选区（anchor 不动端 + head 活动端）")
;;; ===========================================================================

;; selection : point point → selection
;;   设计：用「不动端 anchor + 活动端 head」表达方向，比 (start,end) 多带方向信息；
;;         head 在 anchor 左边就是反向选区（Shift+左键产生的），core 到处都支持方向。
;;   用法：区间计算一律先 selection-range 归一；取「光标点」用 selection-point（=head）。
(define sel (selection (P 0 0) (P 0 3)))
(show "(selection (point 0 0) (point 0 3))" sel)
(show "(selection-anchor sel)" (selection-anchor sel))
(show "(selection-head sel)" (selection-head sel))

;; caret : point → selection；caret? : selection → boolean；caret-point : selection → point
;;   设计：普通光标就是「空选区」，底层是同一个结构，不必两种类型。
;;   用法：用 caret 造光标、caret? 判光标、caret-point 取点。
(show "(caret (point 0 2))" (caret (P 0 2)))
(show "(caret? (caret (point 0 2)))" (caret? (caret (P 0 2))))
(show "(caret-point (caret (point 0 2)))" (caret-point (caret (P 0 2))))

;; selection-point : selection → point（= head）
(show "(selection-point sel)" (selection-point sel))

;; selection-range : selection → (values start end)
;;   设计：把方向归一成半开正向区间，凡是「要用 [start,end)」的地方都先过它。
(show "(selection-range 反向选区 (0,3)->(0,1))"
      (call-with-values (lambda () (selection-range (selection (P 0 3) (P 0 1)))) list))

;; selection-empty? : selection → boolean
(show "(selection-empty? (selection (point 0 1) (point 0 1)))"
      (selection-empty? (selection (P 0 1) (P 0 1))))

;; selection-map-edit / selections-normalize / selections-primary-index **不在**门面里。
;;   设计：它们是视口重基准的内部工具（住在 core/atom/selection.rkt）；应用面要「端点随编辑移动」
;;         直接用 edit-desc-map-position（下一节）自己映射。
(show "手工映射端点：(edit-desc-map-position 插XX@(0,0) (point 0 1))"
      (edit-desc-map-position (edit-desc (P 0 0) (P 0 0) "XX") (P 0 1)))

;; selection-with-head / -with-anchor / -map-head / -map-anchor / -map-both
;;   设计：**空间变换**（point → point 地搬端点），与「按 edit-desc 映射」是两回事，别混。
;;   用法：扩选（只动 head）、Shift+Home（动 head）、程序化摆选区。
(show "(selection-map-head head→(0,5))" (selection-map-head (lambda (_) (P 0 5)) (selection (P 0 1) (P 0 2))))
(show "(selection-map-anchor anchor→(0,0))" (selection-map-anchor (lambda (_) (P 0 0)) (selection (P 0 1) (P 0 2))))
(show "(selection-with-head sel (point 0 9))" (selection-with-head sel (P 0 9)))

;;; ===========================================================================
(header "3. selection-set —— 命名选区集（多选区 = 区间集 + leader）")
;;; ===========================================================================

;; 设计：多光标不是「一堆 caret」，而是**一个值**：区间集 + 名字 + leader。
;;   · 区间集始终规范化（排序/去重/重叠合并）——插入/删除天然作用到所有区间；
;;   · leader = 「原来的那个单选区」，撤销/Esc 收敛时回到它；
;;   · 名字用于命名区间组（如「全选同词」），core 不解释，只保存。
;; 用法：编辑时把整个 selection-set 当一个选区集合用；收敛回单光标用 selection-set-clear。

;; selection-set-open : (or/c symbol #f) (nonempty-listof selection) [nat] → selection-set
;;   leader-index 是**输入列表**里的下标；规范化（排序/合并）后会追到对应项。
(define s1 (selection (P 0 0) (P 0 3)))
(define s2 (selection (P 0 8) (P 0 11)))
(define s3 (selection (P 0 16) (P 0 19)))
(define g  (selection-set-open 'word (list s1 s2 s3) 1))
(show "(selection-set-open 'word [s1 s2 s3] 1)" g)
(show "(selection-set-name g)" (selection-set-name g))
(show "(selection-set-selections g)" (selection-set-selections g))
(show "(selection-set-leader-index g)" (selection-set-leader-index g))
(show "(selection-set-leader g)" (selection-set-leader g))
(show "(selection-set? g)" (selection-set? g))

;; selection-set-normalize : selection-set → selection-set（重跑规范化）
(show "(selection-set-normalize 含重叠)"
      (selection-set-normalize (selection-set-open 'x (list (selection (P 0 0) (P 0 4)) (selection (P 0 2) (P 0 6))) 1)))

;; selection-set-put-leader : selection-set selection → selection-set（让等于 s 的项成为 leader）
(show "(selection-set-put-leader g s3) → leader" (selection-set-leader (selection-set-put-leader g s3)))

;; selection-set-add / -remove : selection-set (listof selection) → selection-set
;;   设计：并集 / 差集；leader 尽量保持（Ctrl+D 加下一个出现时，当前光标不跳）。
(show "(selection-set-selections (add g [新]))" (selection-set-selections (selection-set-add g (list (selection (P 0 20) (P 0 22))))))
(show "(selection-set-selections (remove g s2))" (selection-set-selections (selection-set-remove g (list s2))))

;; selection-set-map : selection-set (selection → selection) → selection-set
(show "(selection-set-map 全部坍缩到 anchor)"
      (selection-set-selections (selection-set-map g (lambda (s) (caret (selection-anchor s))))))

;; selection-set-clear : selection-set → selection-set（收敛为单个 leader，名字丢弃）
;;   设计：Esc 回单光标的语义——保留 leader，丢掉其余。
(show "(selection-set-clear g)" (selection-set-clear g))

;; selection-set-map-edit / -advance-leader : selection-set (listof edit-desc) → selection-set
;;   设计：两种「编辑后光标去哪」的策略：
;;     map-edit       free：每个端点各自随编辑平移（多光标各自保持相对位置）；
;;     advance-leader leader：都坍缩到插入之后（像单光标打字推进）。
(define d4 (edit-desc (P 0 4) (P 0 4) "XX"))
(show "(selection-set-map-edit g [插XX@(0,4)])"
      (map selection-head (selection-set-selections (selection-set-map-edit g (list d4)))))
(show "(selection-set-advance-leader g [插XX@(0,4)]) → leader"
      (selection-set-leader (selection-set-advance-leader g (list d4))))

;;; ===========================================================================
(header "4. edit-desc —— 文本变更原子 + 位置代数")
;;; ===========================================================================

;; edit-desc : point point string → edit-desc
;;   设计：edit-desc 只描述**变更**（[start,end) 换成 new-text），**不含旧文本**。
;;         因为不含旧文本，它就能被任意打包、重放、跨层传递；旧文本由漏斗在施加时捕获（用于求逆）。
;;         坐标一律是「施加前」——这样一串 desc 可以按固定规则施加而不互相污染。
;;   用法：这是唯一跨层的文本变更契约；批量编辑就是一组 edit-desc。
(define ed (edit-desc (P 0 1) (P 0 4) "XY"))
(show "(edit-desc (point 0 1) (point 0 4) \"XY\")" ed)
(show "(edit-desc-start ed)" (edit-desc-start ed))
(show "(edit-desc-end ed)" (edit-desc-end ed))
(show "(edit-desc-new-text ed)" (edit-desc-new-text ed))

;; edit-desc-map-position : edit-desc point → (or/c point #f)
;;   设计：位置代数——「编辑前的位置在编辑后是哪」。#f = 该点落在被删区间内、已不存在。
;;   用法：选区/光标/属性端点的重定位都基于它（core 自己在漏斗里调用）。
(show "(edit-desc-map-position ed (point 0 0))" (edit-desc-map-position ed (P 0 0)))
(show "(edit-desc-map-position ed (point 0 2))  ; 被删 → #f" (edit-desc-map-position ed (P 0 2)))
(show "(edit-desc-map-position ed (point 0 4))  ; =end" (edit-desc-map-position ed (P 0 4)))

;; edit-desc-after-position : edit-desc → point（插入/替换文本之后的点）
;;   设计：光标推进（leader 语义）的落点。注意「替换」时它是新文本末尾，不是 end。
(show "(edit-desc-after-position ed)" (edit-desc-after-position ed))

;; edit-desc-inverse : edit-desc string → edit-desc（用旧文本求逆）
;;   设计：edit-desc 不含旧文本，所以求逆必须**外部传入**被删掉的旧文本；
;;         这也强制「逆要用编辑前的 buffer 算」（用编辑后的会静默写坏历史）。
(show "(edit-desc-inverse ed \"cde\")" (edit-desc-inverse ed "cde"))

;; edits-normalize : symbol (listof edit-desc) → (listof edit-desc)
;;   设计：一批 desc 必须**两两不重叠**（否则施加顺序会互相改变对方坐标）；
;;         规范化 = 按起点排序 + 重叠检查。同起点零宽插入按输入顺序保留。
;;   用法：任何批量施加前，漏斗会先跑它（报错里的 who 就是传进来的符号）。
(show "(edits-normalize 乱序)"
      (edits-normalize 'demo (list (edit-desc (P 1 0) (P 1 1) "") (edit-desc (P 0 0) (P 0 1) ""))))
(show "(edits-normalize 重叠 → 抛错)"
      (with-handlers ([exn:fail? (lambda (e) (exn-message e))])
        (edits-normalize 'demo (list (edit-desc (P 0 1) (P 0 3) "") (edit-desc (P 0 2) (P 0 4) "")))))

;; edits-map-position : (listof edit-desc) point → point
;;   设计：把一个点依次映射过一串「施加顺序的」编辑；落在零宽插入点上会落到插入之后
;;         （光标跟随右边文本），落在删除区间内吸附到区间起点（不消失）。
(show "(edits-map-position [插X@(0,1)] (point 0 1))"
      (edits-map-position (list (edit-desc (P 0 1) (P 0 1) "X")) (P 0 1)))

;; edits-span : (listof edit-desc) → (values first-line last-line)
;;   设计：给增量重绘用的「受影响行区间」（新坐标系）；空 → #f #f。
(show "(edits-span 空)" (call-with-values (lambda () (edits-span '())) list))
(show "(edits-span [插 M\\nN\\n @(1,0)])"
      (call-with-values (lambda () (edits-span (list (edit-desc (P 1 0) (P 1 0) "M\nN\n")))) list))

;;; ===========================================================================
(header "5. change —— 变更集（文本 + 属性，一次施加）")
;;; ===========================================================================

;; change : (listof edit-desc) (listof attr-desc) → change
;;   设计：core 的**唯一变更单位**。把「文本替换」和「属性变更」打包成一个值，
;;         就能做到「文本 + 给它标只读」= 一次换 buffer、一步撤销。
;;         关键坐标约定：attrs 的坐标 = texts **全部生效之后**（所以可以先插文本再给新文本标属性）。
;;   用法：只改文本时 attrs 为空；只改属性时 texts 为空。
(define ch (change (list (edit-desc (P 0 1) (P 0 1) "X")) '()))
(show "(change [插X] [])" ch)
(show "(change-texts ch)" (change-texts ch))
(show "(change-attrs ch)" (change-attrs ch))

;; edits->change : (listof edit-desc) → change（纯文本便利构造）
(show "(edits->change [插X])" (edits->change (list (edit-desc (P 0 0) (P 0 0) "X"))))
;; attrs->change : (listof attr-desc) → change（纯属性；详见 api/2-attr.rkt）
(show "(attrs->change [set face])" (attrs->change (list (attr-set (P 0 0) (P 0 1) 'face 'bold))))

;; 谓词：给命令层做「这条命令动的是文本还是属性」的分支。
(show "(change-empty? (change '() '()))" (change-empty? (change '() '())))
(show "(change-text-only? (edits->change ...))" (change-text-only? (edits->change (list (edit-desc (P 0 0) (P 0 0) "x")))))
(show "(change-attr-only? (attrs->change ...))" (change-attr-only? (attrs->change (list (attr-set (P 0 0) (P 0 1) 'k #t)))))

;;; ===========================================================================
(header "6. buffer —— 纯文本值（content ⊕ tick）")
;;; ===========================================================================

;; 设计：buffer **只有文本和版本号**，不含属性、也不施加编辑。
;;   为什么拆出来：文本是「文档的内容」里与属性正交的一半；把「文本几何」独立后，
;;   属性、视口、账本都能以同一份坐标工作。
;;   tick = 版本戳，文本变才 +1 —— 给前端做廉价变化检测。
;; 用法：读文本/几何用它；施加编辑一律走 document（buffer 的 op 只「算 desc」）。

;; buffer-open : string → buffer
(define b (buffer-open "hello\nworld"))
(show "(buffer? b)" (buffer? b))
(show "(buffer->string b)" (buffer->string b))
(show "(buffer->lines b)" (buffer->lines b))
(show "(buffer-line-count b)" (buffer-line-count b))
(show "(buffer-line-ref b 0)" (buffer-line-ref b 0))
(show "(buffer-line-length b 0)" (buffer-line-length b 0))
(show "(buffer-tick b)" (buffer-tick b))

;; buffer-clamp-point : buffer point → point
(show "(buffer-clamp-point b (point 9 9))" (buffer-clamp-point b (P 9 9)))

;; buffer-point->offset / buffer-offset->point : buffer point|nat → nat|point
;;   设计：point ↔ 全文字符 offset 的双向换算（给 LSP / 搜索 / 序列化用）。
(show "(buffer-point->offset b (point 1 0))" (buffer-point->offset b (P 1 0)))
(show "(buffer-offset->point b 8)" (buffer-offset->point b 8))

;; buffer-range-text : buffer point point → string（[start,end) 半开，可跨行）
(show "(buffer-range-text b (point 0 1) (point 1 2))" (buffer-range-text b (P 0 1) (P 1 2)))

;; buffer-clamp-edit-descs : buffer (listof edit-desc) → (listof edit-desc)（夹到合法域，不改 buffer）
;;   设计：外来编辑（LSP 给的区间）可能越界，先夹到合法域再交给漏斗。
(show "(buffer-clamp-edit-descs b [edit 0,1→0,99])"
      (buffer-clamp-edit-descs b (list (edit-desc (P 0 1) (P 0 99) ""))))

;; buffer-content-eq? : buffer buffer → boolean
;;   设计：只有真正换 content 才不等（编辑后产生新 content 值）；比字符串比较快。
(show "(buffer-content-eq? b b)" (buffer-content-eq? b b))
;; buffer-content : buffer → content（文本原子；给漏斗/渲染用，一般不直接用）
(show "(buffer-content b)" (buffer-content b))

;; ---- 文本动作（只算 desc，不施加）----
;; 设计：buffer-op-* 是**值**（函数）：buffer selection → desc/#f。只读 buffer 算变更，不写。
;;   这样「编辑动作」与「谁施加、怎么记账、光标怎么动」彻底解耦。
;; 用法：喂给 document-edit-at（§7）；#f 表示该动作在此上下文无意义（如空操作）。
(define op-ins (buffer-op-insert "hi"))
(show "((buffer-op-insert \"hi\") b (caret (0,0)))" (op-ins b (caret (P 0 0))))
(show "((buffer-op-insert-char #\\X) b (caret (0,0)))" ((buffer-op-insert-char #\X) b (caret (P 0 0))))
(show "((buffer-op-newline) b (caret (0,5)))" ((buffer-op-newline) b (caret (P 0 5))))
(show "((buffer-op-backspace) b (caret (1,0)))" ((buffer-op-backspace) b (caret (P 1 0))))
(show "((buffer-op-delete) b (caret (0,0)))" ((buffer-op-delete) b (caret (P 0 0))))
(show "((buffer-op-splice (0,0) (0,5) \"HELLO\") b sel)" ((buffer-op-splice (P 0 0) (P 0 5) "HELLO") b (caret (P 0 0))))

;; buffer-edit-desc-inverse : buffer edit-desc → edit-desc（用**编辑前** buffer 求逆）
(show "(buffer-edit-desc-inverse b (edit 0,1→0,3 \"Z\"))"
      (buffer-edit-desc-inverse b (edit-desc (P 0 1) (P 0 3) "Z")))

;;; ===========================================================================
(header "7. document —— 可编辑根（buffer ⊕ attrs），唯一变更漏斗")
;;; ===========================================================================

;; 设计：document = buffer（文本）+ attrs（标注）。**所有文本/属性编辑都必须经过它**，
;;   于是守卫（read-only）、属性跟随、版本戳、撤销材料只有一份实现，不可能分叉。
;;   `document-apply-change` 返回的 change-result 同时包含「生效了什么」和「怎么撤销」——
;;   这是「一步撤销」和「前端增量处理」的共同依据。
;; 用法：读用 document-*；写用下面三个漏斗（apply-change 通用 / apply-edit 单条 / edit-at 位置+op）。

;; document-open : string → document
(define d0 (document-open "hello\nworld"))
(show "(document->string d0)" (document->string d0))
(show "(document->lines d0)" (document->lines d0))
(show "(document-line-count d0)" (document-line-count d0))
(show "(document-line-ref d0 1)" (document-line-ref d0 1))
(show "(document-line-length d0 1)" (document-line-length d0 1))
(show "(document-text-tick d0)  ; 文本版本" (document-text-tick d0))
(show "(document-attr-tick d0)  ; 属性版本（分开，便于只重投影）" (document-attr-tick d0))
(show "(document-buffer d0)" (document-buffer d0))
(show "(document-attrs d0)" (document-attrs d0))

;; document-clamp-point / -point->offset / -offset->point / -range-text / -clamp-edit-descs
;;   设计：与 buffer 同名的读口是转发（文档层便利），坐标是字符索引。
(show "(document-clamp-point d0 (point 9 9))" (document-clamp-point d0 (P 9 9)))
(show "(document-point->offset d0 (point 1 0))" (document-point->offset d0 (P 1 0)))
(show "(document-offset->point d0 6)" (document-offset->point d0 6))
(show "(document-range-text d0 (point 0 1) (point 1 2))" (document-range-text d0 (P 0 1) (P 1 2)))
;; document-clamp-edit-descs : document (listof edit-desc) → (listof edit-desc)（夹到合法域，不改文档）
(show "(document-clamp-edit-descs d0 [edit 0,1→0,99])"
      (document-clamp-edit-descs d0 (list (edit-desc (P 0 1) (P 0 99) ""))))
;; document-attrs-eq? : document document → boolean（属性引用相等；比逐段比较快）
(show "(document-attrs-eq? d0 d0)" (document-attrs-eq? d0 d0))

;; document-apply-change : document change [#:trusted?] → (values document (or/c change-result #f))
;;   设计：唯一漏斗。#:trusted? #f（默认）会跑 read-only 守卫；#f 结果 = 整条 change 没发生。
;;   用法：批量/文本+属性混合编辑走它；需要单条便利见下。
(define-values (d1 res)
  (document-apply-change d0 (edits->change (list (edit-desc (P 0 0) (P 0 0) "X")))))
(show "(document->string 插X@(0,0))" (document->string d1))
(show "change-result? res" (change-result? res))
;; change-result 两部分：
;;   ① 生效内容（applied-*）：给前端做增量（同步镜像文档、局部重绘）；
(show "(change-result-applied-texts res)" (change-result-applied-texts res))
(show "(change-result-applied-attrs res)" (change-result-applied-attrs res))
(show "(change-result-text-inverses res)  ; 文本逆（与 applied 平行）" (change-result-text-inverses res))
;;   ② 撤销材料（replay/undo）：给账本记「一步」。
(show "(change-result-replay res)" (change-result-replay res))
(show "(change-result-undo res)" (change-result-undo res))
(show "(document-text-tick d1)  ; 文本 +1" (document-text-tick d1))

;; 用 change-result-undo 撤回去（正序依次施加，trusted 绕守卫）
(define d1-undo
  (for/fold ([d d1]) ([c (in-list (change-result-undo res))])
    (let-values ([(d* _) (document-apply-change d c #:trusted? #t)]) d*)))
(show "(document->string 撤销后)" (document->string d1-undo))

;; document-apply-edit : document edit-desc → (values document (or/c edit-desc #f))
;;   设计：单条文本的便利封装（等价于 apply-change 一条 texts）。
(define-values (d2 app2) (document-apply-edit d0 (edit-desc (P 0 5) (P 0 5) "!")))
(show "(document->string document-apply-edit)" (document->string d2))
(show "生效 desc" app2)

;; document-edit-at : document point (buffer op) → (values document (or/c edit-desc #f))
;;   设计：给「位置 + 动作」的便利入口；op 是 **buffer op**（buffer selection → desc）。
(define-values (d3 app3) (document-edit-at d0 (P 0 0) (buffer-op-insert ">>")))
(show "(document->string document-edit-at)" (document->string d3))
(show "生效 desc" app3)

;; document-apply-edit-batch : document (listof edit-desc) → (values document applied-descs inverses)
;;   设计：批量文本的显式入口——一次施加、一次 tick；非重叠由 edits-normalize 保证。
(define-values (dbatch apps4 invs4)
  (document-apply-edit-batch d0 (list (edit-desc (P 0 1) (P 0 1) "A")
                                      (edit-desc (P 1 1) (P 1 1) "B"))))
(show "(document->string 批量两处插入)" (document->string dbatch))
(show "applied-descs（施加顺序 = 起点倒序）" apps4)
(show "inverses（与 applied 平行）" invs4)

;;; ===========================================================================
(header "8. history —— 撤销/重放账本（**不在** core/api.rkt 门面里）")
;;; ===========================================================================

;; 设计：账本住 core/unit/history.rkt（纯数据）。一步 = 正反两串 change（自含），
;;       连续打字会按结构规则合并成一步。应用面**不直接用它**，用 editor-undo/redo
;;       （见 api-temp/editor/1-edit.rkt），那里负责把账本和视图/光标串起来。
;; 想拿「一步的正反两种 change」，document-apply-change 的 change-result 已经给了：
(show "change-result-replay res" (change-result-replay res))
(show "change-result-undo res"  (change-result-undo res))

;;; ===========================================================================
(header "9. 事件（输入是类型化值）")
;;; ===========================================================================

;; 设计：输入被建模成**类型化值**（text/key/mouse/resize/quit + modifiers），
;;       后端把原始终端/GUI 事件翻译成这些值，core 只认它们 —— 于是后端可替换、可测试。
;; 用法：事件循环里 match 类型，分派到语义操作；modifiers 用谓词读。

;; modifiers : bool bool bool bool → modifiers（control alt shift meta）
(show "(modifiers #t #f #f #f)" (modifiers #t #f #f #f))
(show "(modifiers-control ...)" (modifiers-control (modifiers #t #f #f #f)))
;; text-event / key-event / mouse-press-event / mouse-wheel-event / resize-event / quit-event
;;   + 各自谓词与读口（text-event-text / key-event-key / key-event-modifiers / …）
(show "(text-event \"中\" (modifiers #f #f #f #f))" (text-event "中" (modifiers #f #f #f #f)))
(show "(text-event-text ...)" (text-event-text (text-event "中" (modifiers #f #f #f #f))))
(show "(key-event 'left (modifiers #f #f #f #f))" (key-event 'left (modifiers #f #f #f #f)))
(show "(key-event-key ...)" (key-event-key (key-event 'left (modifiers #f #f #f #f))))
(show "(resize-event 24 80)" (resize-event 24 80))
(show "(quit-event)" (quit-event))

(printf "\napi/1-edit.rkt 跑完（没有报错）。\n")
