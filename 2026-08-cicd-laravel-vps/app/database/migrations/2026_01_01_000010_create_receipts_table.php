<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/*
| A tiny table with a `legacy_note` column that "old" code reads (see the /report
| route). Scar 5: a one-step deploy that drops legacy_note makes any still-running
| old pod 500 on /report. The expand-contract fix drops it only AFTER a deploy
| that stops reading it.
*/
return new class extends Migration
{
    public function up(): void
    {
        Schema::create('receipts', function (Blueprint $table) {
            $table->id();
            $table->integer('amount')->default(0);
            $table->string('legacy_note')->nullable();   // the column old code still selects
            $table->timestamps();
        });

        \DB::table('receipts')->insert([
            ['amount' => 100, 'legacy_note' => 'seed', 'created_at' => now(), 'updated_at' => now()],
        ]);
    }

    public function down(): void
    {
        Schema::dropIfExists('receipts');
    }
};
